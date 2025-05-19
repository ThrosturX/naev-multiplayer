#!/usr/bin/python

import enet
import time
import logging
from threading import Thread
from typing import Dict
from uuid import uuid4

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('server_relay.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class ServerRelay:
    def __init__(self, host: str = "0.0.0.0", port: int = 60939, max_peers: int = 100, timeout: float = 600.0):
        """
        Initialize the Nauckyev multiplayer server relay (root node).
        
        Args:
            host: IP address to bind the server (default: 0.0.0.0 for all interfaces)
            port: Port to listen on (default: 60939, as per naev-multiplayer)
            max_peers: Maximum number of connected peers
            timeout: Time (seconds) before a server is considered stale
        """
        self.host = host
        self.port = port
        self.max_peers = max_peers
        self.timeout = timeout
        self.servers: Dict[str, Dict] = {}  # Maps server_id to server info
        self.running = False
        self.enet_host = None
        
    def start(self):
        """Start the server relay."""
        try:
            # Initialize ENet host
            self.enet_host = enet.Host(
                enet.Address(self.host, self.port),
                peerCount=self.max_peers,
                channelLimit=1,  # Single reliable channel, as per relay.lua
                incomingBandwidth=0,
                outgoingBandwidth=0
            )
            self.running = True
            logger.info(f"Server relay started on {self.host}:{self.port}")
            
            # Start cleanup thread
            Thread(target=self._cleanup_stale_servers, daemon=True).start()
            
            # Main event loop
            self._event_loop()
            
        except Exception as e:
            logger.error(f"Failed to start server relay: {e}")
            self.stop()
            
    def stop(self):
        """Stop the server relay."""
        self.running = False
        if self.enet_host:
            for peer in self.enet_host.peers:
                peer.disconnect()
            self.enet_host = None
        logger.info("Server relay stopped")
        
    def _event_loop(self):
        """Process ENet events."""
        while self.running:
            try:
                event = self.enet_host.service(1000)  # Timeout in ms
                if event is None:
                    continue
                    
                if event.type == enet.EVENT_TYPE_CONNECT:
                    logger.info(f"Peer connected: {event.peer.address}")
                    
                elif event.type == enet.EVENT_TYPE_DISCONNECT:
                    self._handle_disconnect(event.peer)
                    
                elif event.type == enet.EVENT_TYPE_RECEIVE:
                    self._handle_packet(event.peer, event.packet)
                    
            except Exception as e:
                logger.error(f"Error in event loop: {e}")
                
    def _handle_disconnect(self, peer: enet.Peer):
        """Handle peer disconnection."""
        server_ids = [sid for sid, info in self.servers.items() if info['peer'] == peer]
        for sid in server_ids:
            self._broadcast_deadvertise(self.servers[sid]['system'])
            del self.servers[sid]
            logger.info(f"Server {sid} disconnected and deadvertised")
        logger.info(f"Peer {peer.address} disconnected")
            
    def _handle_packet(self, peer: enet.Peer, packet: enet.Packet):
        """Process received packet."""
        try:
            data = packet.data.decode('utf-8').strip()
            parts = data.split('\n')
            if not parts:
                logger.warning("Empty packet received")
                return
                
            cmd = parts[0]
            
            if cmd == 'add':
                self._handle_add(peer, parts[1:])
            elif cmd == 'list' or cmd == 'update':
                self._handle_list(peer)
            elif cmd == 'ping':
                self._handle_ping(peer, parts[1:])
            elif cmd == 'remove':
                self._handle_remove(peer, parts[1:])
            elif cmd == 'advertise':
                self._handle_advertise(peer, parts[1:])
            elif cmd == 'deadvertise':
                self._handle_deadvertise(peer, parts[1:])
            elif cmd == 'find_peer':
                self._handle_find_peer(peer, parts[1:])
            else:
                logger.warning(f"Unknown command: {cmd}")
                response = f"{cmd} error Unknown command"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                
        except UnicodeDecodeError as e:
            logger.error(f"Invalid packet encoding: {e}")
            
    def _handle_add(self, peer: enet.Peer, args: list):
        """Handle add command to register a server."""
        try:
            if len(args) < 4:
                raise ValueError("Too few arguments: expected addr, port, system, name")
                
            addr, port, system = args[:3]
            name = ' '.join(args[3:])  # Name may contain spaces
            port = int(port)
            
            server_info = {
                'addr': addr,
                'port': port,
                'system': system,
                'name': name,
                'last_ping': time.time(),
                'peer': peer
            }
            server_id = str(uuid4())
            self.servers[server_id] = server_info
            
            # Send acknowledgment
            response = f"add {server_id} ok"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            logger.info(f"Registered server {server_id}: {name} hosting {system}")
            
        except ValueError as e:
            logger.error(f"Error handling add command: {e}")
            response = f"add error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_list(self, peer: enet.Peer):
        """Handle list or update command to return server list."""
        try:
            if not self.servers:
                response = "list empty"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.info(f"Sent empty server list to {peer.address}")
                return
                
            # Build response with one server per line
            response_lines = [
                f"list {sid} {info['addr']} {info['port']} {info['system']} {info['name']}"
                for sid, info in self.servers.items()
            ]
            response = '\n'.join(response_lines)
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            logger.info(f"Sent server list to {peer.address}: {len(self.servers)} servers")
            
        except Exception as e:
            logger.error(f"Error handling list command: {e}")
            response = f"list error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_ping(self, peer: enet.Peer, args: list):
        """Handle ping command to update server status."""
        try:
            if len(args) != 1:
                raise ValueError("Invalid ping command: expected server_id")
                
            server_id = args[0]
            if server_id in self.servers:
                self.servers[server_id]['last_ping'] = time.time()
                response = f"ping {server_id} ok"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.debug(f"Ping received from server {server_id}")
            else:
                response = f"ping {server_id} error Unknown server"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.warning(f"Ping from unknown server {server_id}")
                
        except ValueError as e:
            logger.error(f"Error handling ping command: {e}")
            response = f"ping error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_remove(self, peer: enet.Peer, args: list):
        """Handle remove command to deregister a server."""
        try:
            if len(args) != 1:
                raise ValueError("Invalid remove command: expected server_id")
                
            server_id = args[0]
            if server_id in self.servers:
                del self.servers[server_id]
                response = f"remove {server_id} ok"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.info(f"Removed server {server_id}")
            else:
                response = f"remove {server_id} error Unknown server"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.warning(f"Remove request for unknown server {server_id}")
                
        except ValueError as e:
            logger.error(f"Error handling remove command: {e}")
            response = f"remove error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_advertise(self, peer: enet.Peer, args: list):
        """Handle advertise command to register and broadcast a server."""
        try:
            if len(args) != 1:
                raise ValueError("Invalid advertise command: expected system")
                
            system = args[0]
            
            server_info = {
                'addr': peer.address.host,
                'port': peer.address.port,
                'system': system,
                'name': 'Unknown',  # Name not provided in advertise
                'last_ping': time.time(),
                'peer': peer
            }
            server_id = str(uuid4())
            self.servers[server_id] = server_info
            
            # Send acknowledgment
            response = f"advertise {server_id} ok"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
            # Broadcast to other peers
            self._broadcast_advertise(system, peer)
            logger.info(f"Advertised server {server_id} hosting {system}")
            
        except ValueError as e:
            logger.error(f"Error handling advertise command: {e}")
            response = f"advertise error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_deadvertise(self, peer: enet.Peer, args: list):
        """Handle deadvertise command to deregister and broadcast server removal."""
        try:
            if len(args) != 1:
                raise ValueError("Invalid deadvertise command: expected system")
                
            system = args[0]
            server_id = None
            for sid, info in self.servers.items():
                if info['system'] == system and info['peer'] == peer:
                    server_id = sid
                    break
                    
            if server_id:
                self._broadcast_deadvertise(system, peer)
                del self.servers[server_id]
                response = f"deadvertise {server_id} ok"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.info(f"Deadvertised server {server_id} for {system}")
            else:
                response = f"deadvertise error Unknown system"
                peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                logger.warning(f"Deadvertise request for unknown system {system}")
                
        except ValueError as e:
            logger.error(f"Error handling deadvertise command: {e}")
            response = f"deadvertise error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _handle_find_peer(self, peer: enet.Peer, args: list):
        """Handle find_peer command to locate a server hosting a solar system."""
        try:
            if len(args) < 1:
                raise ValueError("Invalid find_peer command: expected solar_system")
                
            solar_system = ' '.join(args)  # System name may contain spaces
            for sid, info in self.servers.items():
                if info['system'].lower() == solar_system.lower():
                    response = f"find_peer {sid} {info['addr']} {info['port']} {info['system']} {info['name']}"
                    peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
                    logger.info(f"Found server {sid} for system {solar_system}")
                    return
                    
            response = f"find_peer error System not hosted"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            logger.info(f"No server found for system {solar_system}")
            
        except ValueError as e:
            logger.error(f"Error handling find_peer command: {e}")
            response = f"find_peer error {str(e)}"
            peer.send(0, enet.Packet(response.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            
    def _broadcast_advertise(self, system: str, exclude_peer: enet.Peer):
        """Broadcast advertise message to all peers except the sender."""
        try:
            message = f"advertise\n{system}\n"
            for peer in self.enet_host.peers:
                if peer != exclude_peer and peer.state == enet.PEER_STATE_CONNECTED:
                    peer.send(0, enet.Packet(message.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            logger.debug(f"Broadcasted advertise for system {system}")
            
        except Exception as e:
            logger.error(f"Error broadcasting advertise: {e}")
            
    def _broadcast_deadvertise(self, system: str, exclude_peer: enet.Peer = None):
        """Broadcast deadvertise message to all peers except the exclude_peer."""
        try:
            message = f"deadvertise\n{system}\n"
            for peer in self.enet_host.peers:
                if peer != exclude_peer and peer.state == enet.PEER_STATE_CONNECTED:
                    peer.send(0, enet.Packet(message.encode('utf-8'), enet.PACKET_FLAG_RELIABLE))
            logger.debug(f"Broadcasted deadvertise for system {system}")
            
        except Exception as e:
            logger.error(f"Error broadcasting deadvertise: {e}")
            
    def _cleanup_stale_servers(self):
        """Remove servers that haven't pinged recently and broadcast deadvertise."""
        while self.running:
            try:
                current_time = time.time()
                stale = [
                    sid for sid, info in self.servers.items()
                    if current_time - info['last_ping'] > self.timeout
                ]
                for sid in stale:
                    system = self.servers[sid]['system']
                    self._broadcast_deadvertise(system)
                    del self.servers[sid]
                    logger.info(f"Removed and deadvertised stale server {sid} for {system}")
                time.sleep(10.0)  # Check every 10 seconds
            except Exception as e:
                logger.error(f"Error in cleanup: {e}")
                
def main():
    relay = ServerRelay()
    try:
        relay.start()
    except KeyboardInterrupt:
        logger.info("Shutting down server relay")
        relay.stop()

if __name__ == "__main__":
    main()
