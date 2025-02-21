/*
*	GM networking system | v1.0.1
*	Github: https://github.com/Antidissmist/gm_networking_system
*	Author: Antidissmist
*/


#macro NET_VERSION 1
#macro NET_PORT_DEFAULT 6510
#macro NET_PORT_LAN_BROADCAST_DEFAULT 6511
#macro NET_LAN_BROADCAST_FREQUENCY_SECONDS 3 //how often to broadcast our info (ip/port) over LAN
#macro NET_PACKET_RETRY_COUNT 3 //number of times to retry sending a packet before we give up and close the connection
#macro NET_PACKET_RETRY_FREQUENCY_SECONDS 1
#macro NET_REQUEST_TIMEOUT_SECONDS 5 //time before a request times out and returns on_error
#macro NET_PING_FREQUENCY_SECONDS 5
#macro NET_AUTOKICK_MAX_PING_MS 5_000 //if a client's ping exceeds this, they are kicked. -1 to disable.
#macro NET_ALL_CLIENTS "all"
#macro NET_CALLBACK_FINISH "__done"

#macro NET_BUFFER global._net_buffer
NET_BUFFER = buffer_create(512,buffer_grow,1);

#macro NET_EVENTS global._net_events
NET_EVENTS = {
	
	connect_setup: "_connect_setup",
	udp_setup: "_udp_setup",
	request_reply: "_req_reply",
	
	any: "*",
	ping: "ping",
	connected: "connected",
	connect_failed: "connect_failed",
	packet_failed: "packet_failed",
	disconnected: "disconnected",
	
};
//unique-ish key to avoid confusion with other packets we might receive
#macro NET_KEY_PACKET_TYPE "_ntype_"
#macro NET_PACKET_TYPES global._net_packet_types
NET_PACKET_TYPES = {
	normal: "pack",
	lan_broadcast: "lanb",
};



function net_functions() constructor {
	
	//checkers
	static version_compatible = function(client,server) {
		return client == server;
	}
	
	static event_type_is_valid = function(type) {
		return is_string(type);
	}
	
	static event_data_is_valid = function(dat) {
		return true; //may be struct, array, integer or anything json-able, also undefined for no data
	}
	
	static version_is_valid = function(val) {
		return is_numeric(val);
	}
	
	static uuid_is_valid = function(val) {
		return is_string(val);
	}
	
	static is_socket = function(val) {
		return is_numeric(val);
	}
	
	static is_client = function(val) {
		return is_struct(val);
	}
	
	//other
	static create_uuid = function(unique_key_struct=undefined) {
		var str;
		do {
			str = md5_string_unicode($"{get_timer()},{date_current_datetime()},{random(2_000_000)}");
			str = string_replace_all(str," ","");
		} until (
			!is_struct(unique_key_struct)
			|| !variable_struct_exists(unique_key_struct,str)
		);
		return str;
	}
	
}
new net_functions(); //static init






///@desc parent for something that does network things
function net_interface() constructor {
	
	
	request_id = 0; //id to associate a request with a reply
	reply_promises = {}; //functions to be called when we get a reply
	event_handlers = {}; //functions to be called when an event runs
	callbacks = ds_list_create(); //things to be called later (send retries,request timeouts)
	
	_on_invalid_packet = do_nothing; // (from)
	_get_reply_socket = function(from) {
		return from.socket_tcp;
	};
	
	///@desc adds a handler to the list of things called on this event
	static on = function(type,handler,clearable=true) {
		event_handlers[$ type] ??= [];
		array_push(event_handlers[$ type],{
			func: handler,
			clearable,
		});
	}
	///@desc clears all (clearable) event handlers for this event type
	static clear_event = function(type) {
		var arr = event_handlers[$ type];
		if !is_undefined(arr) {
			var newarr = array_filter(arr,function(handler){
				return !handler.clearable;
			});
			
			if array_length(newarr)==0 {
				variable_struct_remove(event_handlers,type);
			}
			else {
				event_handlers[$ type] = newarr;
			}
		}
	}
	///@desc receive and handle a packet
	static receive_packet = function(packet,from=undefined) {
		
		var type = packet[$ "type"];
		var data = packet[$ "data"];
		var reqid = packet[$ "reqid"]; //only if it's a request
		
		if !net_functions.event_type_is_valid(type)
		|| !net_functions.event_data_is_valid(data)
		{
			if !is_undefined(from) {
				_on_invalid_packet(from);
			}
			else {
				net_log($"invalid packet! {packet}");
			}
			return;
		}
		
		if type!=NET_EVENTS.any && variable_struct_exists(event_handlers,NET_EVENTS.any) {
			var pack2 = variable_clone(packet);
			pack2.type = NET_EVENTS.any;
			variable_struct_remove(pack2,"reqid");
			pack2[$ "packet_type"] = type;
			receive_packet(pack2,from);
		}
		
		if variable_struct_exists(event_handlers,type) {
			
			//run all handlers and look for a return value
			var response = undefined;
			var handlers = event_handlers[$ type];
			var len = array_length(handlers);
			if len==0 {
				return;
			}
			var handler,retval;
			for(var i=0; i<len; i++) {
				handler = handlers[i];
				retval = handler.func(data,from); //run handler
				if !is_undefined(retval) {
					if !is_undefined(response) {
						net_log($"multiple return values for event {type}! which to choose??");
					}
					response = retval;
				}
			}
			
			if !is_undefined(reqid) {
				var pack = {
					reqid,
					response,
				};
				_helper_send_tcp(_get_reply_socket(from),NET_EVENTS.request_reply,pack);
			}
			else if !is_undefined(response) {
				net_log($"handler {type} called without return address");
			}
		}
		else {
			//no event handler (do nothing??)
		}
	}
	///@desc simply calls an event
	static run_event = function(type,data=undefined,from=undefined) {
		receive_packet(
			{
				type,
				data,
			},
			from
		);
	}
	
	///@desc start a new callback
	static callback_create = function(period,reps,callback,args=undefined) {
		if reps==0 return undefined;
		
		var str = new net_callback(period,reps,callback,args);
		str.onfinish = method(self,callbacks_check);
		ds_list_add(callbacks,str);
		
		return str;
	}
	///@desc removes finished callbacks
	static callbacks_check = function() {
		if !ds_exists(callbacks,ds_type_list) return;
		var len = ds_list_size(callbacks);
		var callback;
		for(var i=len-1; i>=0; i--) {
			callback = callbacks[| i];
			if callback.finished {
				ds_list_delete(callbacks,i);
			}
		}
	}
	///@desc remove all callbacks
	static callbacks_clear = function() {
		var len = ds_list_size(callbacks);
		for(var i=0; i<len; i++) {
			callbacks[| i].cleanup();
		}
		ds_list_clear(callbacks);
	}
	
	///@desc send TCP data to a socket
	static _helper_send_tcp = function(socket,type,data,retries=NET_PACKET_RETRY_COUNT) {
		if !net_functions.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_functions.event_type_is_valid(type) {
			show_error("invalid event type!",true);
		}
		var buff = NET_BUFFER;
		//var size = net_write_data(type,data,buff);
		var size = net_write_json({ type, data });
		var status = network_send_packet(socket,buff,size);
		if status<0 {
			if retries > 0 {
				net_log("TCP send failed! retrying...");
				callback_create(NET_PACKET_RETRY_FREQUENCY_SECONDS,1,method(self,_helper_send_tcp),[socket,type,data,retries-1]);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
		}
	}
	///@desc send UDP data to a socket
	static _helper_send_udp = function(socket,ip,port,type,data,retries=NET_PACKET_RETRY_COUNT) {
		if !net_functions.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_functions.event_type_is_valid(type) {
			show_error("invalid event type!",true);
		}
		var buff = NET_BUFFER;
		//var size = net_write_data(type,data,buff);
		var size = net_write_json({ type, data });
		var status = network_send_udp(socket,ip,port,buff,size);
		if status<0 {
			if retries > 0 {
				net_log("UDP send failed! retrying...");
				callback_create(NET_PACKET_RETRY_FREQUENCY_SECONDS,1,method(self,_helper_send_udp),[socket,ip,port,type,data,retries-1]);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
		}
	}
	///@desc request something and get a reply
	static _helper_request = function(socket,type,data,response_func=do_nothing,retries=NET_PACKET_RETRY_COUNT,reuse_reqid=undefined) {
		if !net_functions.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_functions.event_type_is_valid(type) {
			show_error("invalid event type!",true);
		}
		
		var reqid = reuse_reqid ?? request_id;
		var buff = NET_BUFFER;
		var size = net_write_json({ 
			type, 
			data,
			reqid: reqid
		});
		if is_undefined(reuse_reqid) {
			var promise = new net_promise();
			if does_something(response_func) {
				promise.on_response(response_func);
			}
			reply_promises[$ string(reqid)] = promise;
			request_id++
		}
		else {
			var promise = reply_promises[$ string(reqid)];
		}
		
		var status = network_send_packet(socket,buff,size);
		if status<0 {
			if retries > 0 {
				net_log("request send failed! retrying...");
				callback_create(NET_PACKET_RETRY_FREQUENCY_SECONDS,1,method(self,_helper_request),[socket,type,data,response_func,retries-1,reqid]);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
			return;
		}
		else {
			callback_create(NET_REQUEST_TIMEOUT_SECONDS,1,function(promise,reqid){
				if variable_struct_exists(reply_promises,reqid) {
					net_log("request timed out");
					reply_promises[$ reqid].resolve_error([{ type: "timeout" }]);
					variable_struct_remove(reply_promises,reqid);
				}
			},[promise,reqid]);
		}
		
		
		return promise;
	}
	
	static _cleanup_common = function() {
		
		callbacks_clear();
		ds_list_destroy(callbacks);
		
	}
	
	//get request replies
	on(NET_EVENTS.request_reply,function(dat,from){
		var reqid = dat.reqid;
		var response = dat[$ "response"];
		if variable_struct_exists(reply_promises,reqid) {
			reply_promises[$ reqid].resolve([response,from]);
			variable_struct_remove(reply_promises,reqid);
		}
		else {
			net_log("request reply missing promise!");
		}
	},false);
	on(NET_EVENTS.packet_failed,function(){
		net_log("packet send failed for the last time!");
	},false);
	
}
function net_server(_port=NET_PORT_DEFAULT,_max_clients=8) : net_interface() constructor {
	
	
	is_open = false;
	is_lan_broadcasting = false;
	
	socket_tcp = undefined;
	socket_udp = undefined;
	
	clients_init();
	
	port = _port;
	port_lan_broadcast = NET_PORT_LAN_BROADCAST_DEFAULT;
	max_clients = _max_clients;
	
	
	on_client_disconnected = do_nothing; // (client struct)
	on_client_connected = do_nothing; // (client struct)
	get_lan_server_info = do_nothing; //returns relevant info (name, player count) for lan broadcast
	track_ping = true; //keep track of ping and autokick clients with too high ping
	
	ts_ping = undefined;
	ts_lan_broadcast = undefined;
	
	//client asked to setup connection
	on(NET_EVENTS.connect_setup,function(dat,clientfrom){
		
		var allowed = true;
		var message = ""; 
		
		var vers = dat[$ "version"];
		if !net_functions.version_is_valid(vers) {
			allowed = false;
			message = "invalid version!";
		}
		
		if !net_functions.version_compatible(vers,NET_VERSION) {
			allowed = false;
			message = "client outdated!";
		}
		
		return {
			success: allowed,
			message: message,
			uuid: clientfrom.uuid,
		};
	},false);
	
	//client sends first udp packet, get their port and finish connection
	on(NET_EVENTS.udp_setup,function(dat,clientfrom){
		
		var port = async_load[? "port"];
		var uuid = dat[$ "uuid"];
		if !net_functions.uuid_is_valid(uuid) {
			//politely ask them to disconnect
			_helper_send_udp(socket_udp,async_load[? "ip"],port,NET_EVENTS.disconnected,{ reason: "invalid uuid!" },0);
			return;
		}
		
		clientfrom = client_get_by_uuid(uuid);
		
		if is_undefined(clientfrom.port) {
			clientfrom.port = port;
			client_port_map[$ port] = clientfrom;
		}
		
		send(clientfrom,NET_EVENTS.udp_setup);
		
		//server-side, connection is complete
		on_client_connected(clientfrom);
	},false);
	
	on(NET_EVENTS.packet_failed,function(){
		stop();
	},false);
	
	_on_invalid_packet = function(from) {
		if net_functions.is_client(from) {
			client_kick(from,"Invalid packet!");
		}
	}
	
	///@desc opens the server for connections
	static start = function() {
		var tsock = network_create_server(network_socket_tcp,port,max_clients);
		//var usock = network_create_server(network_socket_udp,port,max_clients);
		var usock = network_create_socket_ext(network_socket_udp,port);
		if tsock<0 || usock<0 {
			net_log("server start failed!");
			stop();
			return;
		}
		
		socket_tcp = tsock;
		socket_udp = usock;
		is_open = true;
		
		//ping clients
		time_source_destroy_safe(ts_ping);
		if track_ping {
			ts_ping = time_source_create(time_source_global,NET_PING_FREQUENCY_SECONDS,time_source_units_seconds,function(){
				clients_foreach(function(client){
					client._ping_last = get_timer();
				});
				var promise_arr = request(NET_ALL_CLIENTS,NET_EVENTS.ping);
				net_promise_on_each_response(promise_arr,function(data,from_client){
					from_client.ping = round((get_timer() - from_client._ping_last)/1000);
					if NET_AUTOKICK_MAX_PING_MS>0 && from_client.ping>NET_AUTOKICK_MAX_PING_MS {
						client_kick(from_client,$"Maximum ping exceeded! {from_client.ping}/{NET_AUTOKICK_MAX_PING_MS}ms");
					}
				});
			
			},[],-1);
			time_source_start(ts_ping);
		}
	}
	///@desc closes the server and disconnects all clients
	static stop = function() {
		
		//tell clients to disconnect
		if is_open {
			send(NET_ALL_CLIENTS,NET_EVENTS.disconnected,{ reason: "Server closed." });
		}
		
		net_socket_close(socket_tcp);
		net_socket_close(socket_udp);
		socket_tcp = undefined;
		socket_udp = undefined;
		broadcast_to_lan(false);
		time_source_destroy_safe(ts_ping);
		clients_clear();
		is_open = false;
	}
	///@desc start/stop broadcasting server info over LAN
	static broadcast_to_lan = function(state=true,_port=port_lan_broadcast) {
		time_source_destroy_safe(ts_lan_broadcast);
		is_lan_broadcasting = false;
		if state {
			if !is_open {
				return;
			}
			is_lan_broadcasting = true;
			port_lan_broadcast = _port;
			var callback = function(){				
				//send server info (packet has ip)
				var extra_info = get_lan_server_info();
				var infostr = {
					version: NET_VERSION,
					server_port: port,
					NET_KEY_PACKET_TYPE: NET_PACKET_TYPES.lan_broadcast
				};
				if !is_undefined(extra_info) {
					infostr[$ "info"] = extra_info;
				}
				var buff = NET_BUFFER;
				var buffsize = net_write_json(infostr,buff);
				var status = network_send_broadcast(socket_udp,port_lan_broadcast,buff,buffsize);
				if status < 0 {
					net_log("lan broadcast failed!");
					broadcast_to_lan(false);
				}
			};
			ts_lan_broadcast = time_source_create(time_source_global,NET_LAN_BROADCAST_FREQUENCY_SECONDS,time_source_units_seconds,callback,[],-1);
			
			//start immediately
			callback();
			time_source_start(ts_lan_broadcast);
		}
	}
	
	static client_get_by_socket = function(sock) {
		return client_map[$ sock];
	}
	static client_get_by_udp_port = function(port) {
		return client_port_map[$ port];
	}
	static client_get_by_uuid = function(uuid) {
		return client_uuid_map[$ uuid];
	}
	static client_remove = function(client) {
		
		var sock = client.socket_tcp;
		if !variable_struct_exists(client_map,sock) return;
		
		if !is_undefined(client.uuid) {
			variable_struct_remove(client_uuid_map,client.uuid);
		}
		if !is_undefined(client.port) {
			variable_struct_remove(client_port_map,client.port);
		}
		
		var ind = array_get_index(client_array,client);
		if ind!=-1 {
			array_delete(client_array,ind,1);
		}
		
		variable_struct_remove(client_map,sock);
		client_count--
		
		network_destroy(client.socket_tcp);
	}
	static client_kick = function(client,reason="You have been kicked.") {
		send(client,NET_EVENTS.disconnected,{ reason });
		client.connected = false;
		network_destroy(client.socket_tcp);
		//client disconnect event should then fire
	}
	static clients_init = function() {
		client_map = {};
		client_uuid_map = {};
		client_port_map = {};
		client_array = [];
		client_count = 0;
	}
	static clients_foreach = function(func) {
		array_foreach(client_array,func);
	}
	static get_clients_filter = function(filter_func) {
		return array_filter(client_array,filter_func);
	}
	static get_clients_except = function(except_client) {
		static dat = { except_client: undefined };
		dat.except_client = except_client;
		return get_clients_filter(method(dat,function(client){
			return client != except_client;
		}));
	}
	static clients_clear = function() {
		clients_init();
	}
	static client_create = function(sock) {
		
		var client = {
			socket_tcp: sock,
			ip: async_load[? "ip"],
			port: undefined, //get from udp
			uuid: net_functions.create_uuid(client_uuid_map), //unique id
			ping: 0, //milliseconds
			_ping_last: 0,
			connected: true, //basically whether their tcp socket is connected
		};
		
		client_map[$ sock] = client;
		client_uuid_map[$ client.uuid] = client;
		array_push(client_array,client);
		
		client_count++
		
		return client;
	}
	
	///@desc handles async event
	static on_async_networking = function() {
		
		var received_data = false;
		var is_udp = false;
		
		var n_id = async_load[? "id"];
		if n_id==socket_tcp || n_id==socket_udp {
			
			var sock = async_load[? "socket"]; //connect/disconnect ONLY
			switch (async_load[? "type"]) {
				
				
				//got connection
				case network_type_connect:
				case network_type_non_blocking_connect:{
					
					client_create(sock);
					
				}break;
				
				
				//got disconnect
				case network_type_disconnect:{
					var client = client_get_by_socket(sock);
					if is_struct(client) {
						
						client.connected = false;
						
						on_client_disconnected(client);
						
						client_remove(client);
					}
				}break;
				
				
				case network_type_data:
					received_data = true;
					is_udp = true;
				break;
				
				
			}
			
		}
		//tcp data
		else {
			received_data = true;
			is_udp = false;
		}
		
		//read data
		if received_data {
			var clientfrom; //will be undefined before udp_setup
			if is_udp {
				clientfrom = client_get_by_udp_port(async_load[? "port"]);
			}
			else {
				clientfrom = client_get_by_socket(async_load[? "id"]);
			}
			//try to parse json
			var buffer = async_load[? "buffer"];
			try {
				var jstr = buffer_peek(buffer, 0, buffer_string );
				var pack = json_parse(jstr);
			}
			catch(e) {
				net_log($"invalid packet: {e}");
				_on_invalid_packet(clientfrom);
				return;
			}
			
			if pack[$ NET_KEY_PACKET_TYPE] != NET_PACKET_TYPES.normal {
				return; //not for us
			}
			
			receive_packet(pack,clientfrom);
		}
		
	}
	
	///@desc send some type of data to some clients. if request, return a promise or array of promises.
	static _helper_server_send = function(to_client,filter_func=return_true,req_type="tcp",type,data=undefined) {
		//multiple clients
		if to_client==NET_ALL_CLIENTS {
			to_client = client_array;
		}
		if is_array(to_client) {
			var len = array_length(to_client);
			var return_array = [];
			var ret_val;
			for(var i=0; i<len; i++) {
				ret_val = _helper_server_send(to_client[i],filter_func,req_type,type,data);
				if !is_undefined(ret_val) {
					if is_array(ret_val) {
						return_array = array_concat(return_array,ret_val);
					}
					else {
						array_push(return_array,ret_val);
					}
				}
			}
			return return_array;
		}
		//individual client
		else {
			if !to_client.connected {
				return;
			}
			if !filter_func(to_client) {
				return;
			}
			if req_type=="udp" {
				_helper_send_udp(socket_udp,to_client.ip,to_client.port,type,data);
			}
			else if req_type=="tcp" {
				_helper_send_tcp(to_client.socket_tcp,type,data);
			}
			else if req_type=="req" {
				return _helper_request(to_client.socket_tcp,type,data);
			}
		}
	}
	
	///@desc send data to: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	static send = function(to_client,type,data=undefined,filter_func=return_true) {
		_helper_server_send(to_client,filter_func,"tcp",type,data);
	}
	///@desc send UDP data to: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	static send_udp = function(to_client,type,data=undefined,filter_func=return_true) {
		_helper_server_send(to_client,filter_func,"udp",type,data);
	}
	///@desc send & request data from: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	static request = function(to_client,type,data=undefined,filter_func=return_true) {
		return _helper_server_send(to_client,filter_func,"req",type,data);
	}
	
	///@desc stops and cleans up dynamic resources
	static cleanup = function() {
		_cleanup_common();
		
		stop();
		
	}
	
}

function net_client() : net_interface() constructor {
	
	
	socket_tcp = undefined;
	socket_udp = undefined;
	ip = "";
	port = 0;
	is_connecting = false;
	is_connected = false;
	
	uuid = undefined;
	
	
	
	//default handlers
	on(NET_EVENTS.connect_failed,function(dat){
		net_log("client connect failed!");
		disconnect();
	},false);
	on(NET_EVENTS.disconnected,function(dat){
		var reason = is_undefined(dat) ? "" : $": {dat[$ "reason"]}";
		net_log($"client disconnected{reason}");
		disconnect();
	},false);
	on(NET_EVENTS.packet_failed,function(dat){
		run_event(NET_EVENTS.disconnected,dat);
	},false);
	on(NET_EVENTS.ping,function(){
		return "pong";
	},false);
	
	_on_invalid_packet = function() {
		//run_event(NET_EVENTS.disconnected,{ reason: "Invalid packet received!" }); //actually don't disconnect
	}
	_get_reply_socket = function() {
		return socket_tcp;
	};
	
	
	ts_udp_setup = undefined;
	//tries to send a first udp packet to the server, so the server has our udp port
	static _udp_setup_begin = function() {
		time_source_destroy_safe(ts_udp_setup);
		var callback = function(){
			send_udp(NET_EVENTS.udp_setup,{
				uuid
			});
		};
		ts_udp_setup = time_source_create(time_source_global,2,time_source_units_seconds,callback,[],-1);
		
		on(NET_EVENTS.udp_setup,function(dat){
			time_source_destroy_safe(ts_udp_setup);
			
			//full connection finished
			is_connecting = false;
			is_connected = true;
			clear_event(NET_EVENTS.udp_setup);
			run_event(NET_EVENTS.connected);
		});
		
		//start immediately
		callback();
		time_source_start(ts_udp_setup);
	}
	
	///@desc ensure our sockets exist
	static check_sockets = function() {
		
		if socket_tcp!=undefined || socket_udp!=undefined {
			return;
		}
		
		var tsock = network_create_socket(network_socket_tcp);
		var usock = network_create_socket(network_socket_udp);
		
		if tsock < 0 
		|| usock < 0 {
			net_log("client socket create failed!");
			run_event(NET_EVENTS.connect_failed);
			return;
		}
		socket_tcp = tsock;
		socket_udp = usock;
		
		is_connected = false;
	}
	
	///@desc connect to a server
	static connect = function(_ip,_port=NET_PORT_DEFAULT) {
		
		check_sockets();
		
		ip = _ip;
		port = _port;
		
		is_connecting = true;
		
		var status = network_connect_async(socket_tcp, ip, port);
		if status < 0 {
			run_event(NET_EVENTS.connect_failed);
			return;
		}
	}
	static disconnect = function() {
		net_socket_close(socket_tcp);
		net_socket_close(socket_udp);
		time_source_destroy_safe(ts_udp_setup);
		socket_tcp = undefined;
		socket_udp = undefined;
		is_connecting = false;
		is_connected = false;
	}
	
	///@desc handles async event
	static on_async_networking = function() {
		
		var n_id = async_load[? "id"];
		if n_id==socket_tcp || n_id==socket_udp {
			
			switch (async_load[? "type"]) {
				
				case network_type_data:{
					var buffer = async_load[? "buffer"];
					try {
						var jstr = buffer_peek(buffer, 0, buffer_string );
						var pack = json_parse(jstr);
					}
					catch(e) {
						net_log($"invalid packet: {e}");
						_on_invalid_packet();
						return;
					}
					
					if pack[$ NET_KEY_PACKET_TYPE] != NET_PACKET_TYPES.normal {
						return; //not for us
					}
					
					receive_packet(pack,"server");
				}break;
				
				case network_type_non_blocking_connect:{
					if async_load[? "socket"]==socket_tcp {
						if async_load[? "succeeded"] {
							_on_tcp_connect();
						}
						else {
							run_event(NET_EVENTS.connect_failed);
						}
					}
				}break;
				
				case network_type_disconnect:{
					if async_load[? "socket"]==socket_tcp {
						run_event(NET_EVENTS.disconnected);
					}
				}break;
				
			}
			
		}
	}
	
	///@desc after first connection, asks server if we are allowed to continue
	static _on_tcp_connect = function() {
		
		request(NET_EVENTS.connect_setup,{
			version: NET_VERSION
		})
		//server responds
		.on_response(function(response){
			if response.success {
				uuid = response.uuid; //get our uuid
				_udp_setup_begin();
			}
			else {
				net_log($"connection refused: {response.message}");
				run_event(NET_EVENTS.connect_failed);
			}
		})
		
	}
	
	///@desc send TCP data to the server
	static send = function(type,data=undefined) {
		_helper_send_tcp(socket_tcp,type,data);
	}
	///@desc send UDP data to the server
	static send_udp = function(type,data=undefined) {
		_helper_send_udp(socket_udp,ip,port,type,data);
	}
	///@desc send & request data from the server
	static request = function(type,data=undefined) {
		return _helper_request(socket_tcp,type,data);
	}
	
	
	///@desc disconnect and clean up all dynamic resources
	static cleanup = function() {
		_cleanup_common();
		
		disconnect();
		
	}
	
}

///@desc listens for servers broadcasted over LAN and gets their info
function net_lan_listener(_port=NET_PORT_LAN_BROADCAST_DEFAULT) constructor {
	
	port = _port;
	
	server_ip_map = {};
	server_array = [];
	
	
	socket_udp = network_create_socket_ext(network_socket_udp,port);
	if socket_udp<0 {
		net_log("LAN listener socket create failed!");
	}
	
	
	static clear_servers = function() {
		server_ip_map = {};
		server_array = [];
	}
	///@desc listen for broadcasted server info
	static on_async_networking = function() {
		var n_id = async_load[? "id"];
		if n_id==socket_udp {
			if async_load[? "type"]==network_type_data {
				var buffer = async_load[? "buffer"];
				try {
					var jstr = buffer_peek(buffer, 0, buffer_string );
					var packet = json_parse(jstr);
				}
				catch(e) {
					return;
				}
				
				if packet[$ NET_KEY_PACKET_TYPE] != NET_PACKET_TYPES.lan_broadcast {
					return; //not for us
				}
				
				packet[$ "ip"] = async_load[? "ip"];
				packet[$ "compatible"] = net_functions.version_compatible(NET_VERSION,packet[$ "version"]);
				
				var serv_id = $"{packet.ip}:{packet.server_port}";
				if !variable_struct_exists(server_ip_map,serv_id) {
					server_ip_map[$ serv_id] = true;
					array_push(server_array,packet);
				}
				
			}
		}
	}
	
	static cleanup = function() {
		net_socket_close(socket_udp);
	}
	
}

///@desc calls a function some time later
function net_callback(_period,_reps,_callback,_args=undefined) constructor {
	
	
	period = _period;
	reps = _reps;
	finished = false;
	onfinish = do_nothing;
	
	callback = _callback;
	args = _args;
	
	ts = time_source_create(time_source_global,period,time_source_units_seconds,method(self,call),[],reps);
	time_source_start(ts);
	
	static call = function() {
		
		var return_val = method_call(callback,args);
		if return_val == NET_CALLBACK_FINISH {
			finish();
			return;
		}
		
		if reps > 0 {
			reps--
			if reps==0 {
				finish();
			}
		}
	}
	
	
	static cleanup = function() {
		time_source_destroy_safe(ts);
	}
	static finish = function() {
		
		cleanup();
		finished = true;
		onfinish();
		
	}
	
}

///@desc calls a function when it's ready
function net_promise() constructor {
	resolved = false;
	listeners_resolve = [];
	listeners_finally = [];
	listeners_error = [];
	
	
	///@desc adds a function to be called when we get a response
	static on_response = function() {
		for(var i=0; i<argument_count; i++) {
			array_push(listeners_resolve,argument[i]);
		}
		return self;
	}
	///@desc adds a function to be called after either a response or an error
	static on_finally = function() {
		for(var i=0; i<argument_count; i++) {
			array_push(listeners_finally,argument[i]);
		}
		return self;
	}
	///@desc adds a function to be called when we get an error/timeout
	static on_error = function() {
		for(var i=0; i<argument_count; i++) {
			array_push(listeners_error,argument[i]);
		}
		return self;
	}
	
	//complete this promise
	static resolve = function(arg_arr) {
		resolved = true;
		var len = array_length(listeners_resolve);
		for(var i=0; i<len; i++) {
			method_call(listeners_resolve[i],arg_arr);
		}
		_resolve_finally(arg_arr);
		return self;
	}
	static _resolve_finally = function(arg_arr) {
		resolved = true;
		var len = array_length(listeners_finally);
		for(var i=0; i<len; i++) {
			method_call(listeners_finally[i],arg_arr);
		}
		return self;
	}
	static resolve_error = function(arg_arr) {
		resolved = true;
		var len = array_length(listeners_error);
		for(var i=0; i<len; i++) {
			method_call(listeners_error[i],arg_arr);
		}
		_resolve_finally(arg_arr);
		return self;
	}
}
///@desc return true when all the given promises are resolved
function net_promise_all_resolved(promise_array) {
	return array_all(promise_array,function(elem){
		return elem.resolved;
	});
}
///@desc add an on_response to each promise in an array
function net_promise_on_each_response(promise_array,on_response) {
	var len = array_length(promise_array);
	for(var i=0; i<len; i++) {
		promise_array[i].on_response(on_response);
	}
}
///@desc add an on_finally to each promise in an array
function net_promise_on_each_finally(promise_array,on_finally) {
	var len = array_length(promise_array);
	for(var i=0; i<len; i++) {
		promise_array[i].on_finally(on_finally);
	}
}
///@desc add an on_error to each promise in an array
function net_promise_on_each_error(promise_array,on_error) {
	var len = array_length(promise_array);
	for(var i=0; i<len; i++) {
		promise_array[i].on_error(on_error);
	}
}


//useful functions
function net_write_data(type,data_struct=undefined,buff=NET_BUFFER) {
	var str = {
		type: type
	};
	if !is_undefined(data_struct) {
		str[$ "data"] = data_struct;
	}
	return net_write_json(str,buff);
}
function net_write_json(struct,buff=NET_BUFFER) {
	struct[$ NET_KEY_PACKET_TYPE] ??= NET_PACKET_TYPES.normal;
	var jstr = json_stringify(struct);
	var bytelen = string_byte_length(jstr)+1;
	buffer_seek(buff,buffer_seek_start,0);
	var status = buffer_write(buff,buffer_string,jstr);
	if status<0 {
		show_error($"network buffer_write error! buffer size: {bytelen}",true);
	}
	return bytelen;
}

function net_socket_close(sock) {
	if net_functions.is_socket(sock) {
		network_destroy(sock);
	}
}
function time_source_destroy_safe(ts,destroyTree=undefined) {
	if time_source_exists(ts) {
		time_source_destroy(ts,destroyTree);
	}
}

function do_nothing(){}
function does_something(val) {
	return is_callable(val) && val!=do_nothing;
}
function return_true(){ return true; }
function net_log(val) {
	show_debug_message(string(val));
}







