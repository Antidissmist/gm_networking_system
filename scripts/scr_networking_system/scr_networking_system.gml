/*
*	GM networking system | v1.0.4 | edited 4/18/26
*	Github: https://github.com/Antidissmist/gm_networking_system
*	Author: Antidissmist
*/
///@feather ignore GM1019

#region config/init

#macro NET_VERSION 1
#macro NET_IP_DEFAULT "127.0.0.1"
#macro NET_PORT_DEFAULT 6510
#macro NET_PORT_LAN_BROADCAST_DEFAULT 6511
//how often to broadcast our info (ip/port) over LAN
#macro NET_LAN_BROADCAST_FREQUENCY_SECONDS 3
//number of times to retry sending a packet before we give up and close the connection
#macro NET_PACKET_RETRY_COUNT 3
#macro NET_PACKET_RETRY_FREQUENCY_SECONDS 1
//time before a request times out and returns on_error
#macro NET_REQUEST_TIMEOUT_SECONDS 5
#macro NET_PING_FREQUENCY_SECONDS 5
//if a client's ping exceeds this, they are kicked. -1 to disable.
#macro NET_AUTOKICK_MAX_PING_MS 5_000
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
	packet_retry: "packet_retry",
	disconnected: "disconnected",
	
};
//unique-ish key to avoid confusion with other packets we might receive
#macro NET_KEY_PACKET_TYPE "_ntype_"
#macro NET_PACKET_TYPES global._net_packet_types
NET_PACKET_TYPES = {
	normal: "pack",
	lan_broadcast: "lanb",
};

#endregion

///@desc Contains general useful functions
function net_system() constructor {
	
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
		if !is_string(val) return false;
		if string_replace_all(val," ","")=="" return false;
		return true;
	}
	
	static is_socket = function(val) {
		return is_numeric(val);
	}
	
	static is_client = function(val) {
		return is_struct(val);
	}
	
	static ip_is_valid = function(val) {
		val = string(val);
		if string_length(val)==0 return false;
		if string_pos(" ",val)!=0 return false; //no spaces
		if string_pos(".",val)==0 return false; //must have at least 1 dot
		return true;
	}
	static port_is_valid = function(val) {
		//must be made of numbers
		val = string(val);
		val = string_digits(val);
		if string_length(val)==0 return false;
		return true;
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
	
	static set_timeout_connection_seconds = function(sec) {
		network_set_config(network_config_connect_timeout,sec*1000);
	}
	
	static destroy_time_source_safe = function(ts,destroyTree=undefined) {
		if time_source_exists(ts) {
			time_source_destroy(ts,destroyTree);
		}
	}
	
	static func_does_something = function(val) {
		return is_callable(val) && val!=net_noop;
	}
}
new net_system(); //static init


///@desc Parent for something that does network things
function net_interface() constructor {
	
	request_id = 0; //id to associate a request with a reply
	reply_promises = {}; //functions to be called when we get a reply
	event_handlers = {}; //functions to be called when an event runs
	callbacks = ds_list_create(); //things to be called later (send retries,request timeouts)
	timeout_connect_seconds = 20;
	
	_on_invalid_packet = net_noop; // (from)
	_get_reply_socket = function(from) {
		return from.socket_tcp;
	};
	
	#region events
	
	///@desc Adds a handler to the list of things called on this event
	/// Handler args: ( data, from )
	///@param {string} eventtype
	///@param {Function} handler
	static on = function(type,handler,clearable=true) {
		event_handlers[$ type] ??= [];
		array_push(event_handlers[$ type],{
			func: handler,
			clearable,
		});
	}
	///@param {string} eventtype
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
		
		if !net_system.event_type_is_valid(type)
		|| !net_system.event_data_is_valid(data)
		{
			if !is_undefined(from) {
				_on_invalid_packet(from);
			}
			else {
				net_log($"invalid packet! {packet}");
			}
			return;
		}
		
		//receive "any" callback first
		if type!=NET_EVENTS.any && variable_struct_exists(event_handlers,NET_EVENTS.any) {
			var pack2 = variable_clone(packet);
			pack2.type = NET_EVENTS.any;
			variable_struct_remove(pack2,"reqid");
			pack2[$ "packet_type"] = type;
			receive_packet(pack2,from);
		}
		
		//receive named event callbacks
		if variable_struct_exists(event_handlers,type) {
			
			//run all handlers and look for a return value
			var response = undefined;
			var handlers = event_handlers[$ type];
			var len = array_length(handlers);
			if len==0 return; //no handlers
			
			var retval;
			for(var i=0; i<len; i++) {
				retval = handlers[i].func(data,from); //run handler
				if !is_undefined(retval) {
					if !is_undefined(response) {
						net_log($"multiple return values for event {type}! which to choose??");
					}
					response = retval;
				}
			}
			
			//send request response
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
	
	///@desc simply calls an event locally
	static run_event = function(type,data=undefined,from=undefined) {
		receive_packet(
			{
				type,
				data,
			},
			from
		);
	}
	
	#endregion
	
	#region callbacks
	
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
		if !ds_exists(callbacks,ds_type_list) return;
		var len = ds_list_size(callbacks);
		for(var i=0; i<len; i++) {
			callbacks[| i].cleanup();
		}
		ds_list_clear(callbacks);
	}
	
	#endregion
	
	#region send helpers
	
	///@desc send TCP data to a socket
	///@param {Id.Socket} socket
	static _helper_send_tcp = function(socket,type,data,retries=NET_PACKET_RETRY_COUNT) {
		if !net_system.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_system.event_type_is_valid(type) {
			show_error("invalid event type!",true);
		}
		var buff = NET_BUFFER;
		//var size = net_write_data(type,data,buff);
		var size = net_write_json({ type, data });
		var status = network_send_packet(socket,buff,size);
		if status<0 {
			if retries > 0 {
				net_log("TCP send failed! retrying...");
				callback_create(
					NET_PACKET_RETRY_FREQUENCY_SECONDS,
					1,
					method(self,_helper_send_tcp),
					[socket,type,data,retries-1]
				);
				run_event(NET_EVENTS.packet_retry);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
		}
	}
	
	///@desc send UDP data to a socket
	///@param {Id.Socket} socket
	static _helper_send_udp = function(socket,ip,port,type,data,retries=NET_PACKET_RETRY_COUNT) {
		if !net_system.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_system.event_type_is_valid(type) {
			show_error("invalid event type!",true);
		}
		var buff = NET_BUFFER;
		//var size = net_write_data(type,data,buff);
		var size = net_write_json({ type, data });
		var status = network_send_udp(socket,ip,port,buff,size);
		if status<0 {
			if retries > 0 {
				net_log("UDP send failed! retrying...");
				callback_create(
					NET_PACKET_RETRY_FREQUENCY_SECONDS,
					1,
					method(self,_helper_send_udp),
					[socket,ip,port,type,data,retries-1]
				);
				run_event(NET_EVENTS.packet_retry);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
		}
	}
	
	///@desc request something and get a reply
	///@param {Id.Socket} socket
	///@returns {Struct.net_promise} promise
	static _helper_request = function(
		socket,
		type,
		data,
		response_func=net_noop,
		retries=NET_PACKET_RETRY_COUNT,
		reuse_reqid=undefined
	) {
		if !net_system.is_socket(socket) {
			show_error("invalid socket!",true);
		}
		if !net_system.event_type_is_valid(type) {
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
			if net_system.func_does_something(response_func) {
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
				callback_create(
					NET_PACKET_RETRY_FREQUENCY_SECONDS,
					1,
					method(self,_helper_request),
					[socket,type,data,response_func,retries-1,reqid]
				);
				run_event(NET_EVENTS.packet_retry);
			}
			else {
				run_event(NET_EVENTS.packet_failed);
			}
			return promise; //note: failure, but on_error is not called
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
	
	#endregion
	
	static _cleanup_common = function() {
		
		callbacks_clear();
		ds_list_destroy(callbacks);
		
	}
	
	#region default events
	
	on(NET_EVENTS.ping,function(){
		return "pong";
	},false);
	
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
	
	#endregion
	
}

function net_server() : net_interface() constructor {
	
	//init variables
	is_open = false;
	is_lan_broadcasting = false;
	
	socket_tcp = undefined;
	socket_udp = undefined;
	ts_ping = undefined;
	ts_lan_broadcast = undefined;
	
	clients_init();
	
	port = undefined;
	port_lan_broadcast = NET_PORT_LAN_BROADCAST_DEFAULT;
	max_clients = undefined;
	
	
	//configurable
	on_stopped = net_noop; //(reason) when the server must stop for some reason (not on cleanup)
	on_client_disconnected = net_noop; // (client struct)
	on_client_connected = net_noop; // (client struct)
	get_lan_server_info = net_noop; //returns relevant info (name, player count) for lan broadcast
	track_ping = true; //keep track of ping and autokick clients with too high ping
	validate_auth_data = function(data) { // (any data) -> struct	 validate their account or something
		static info = { success: true, message: "Success!" };
		return info;
	};
	///@desc (client_struct,generated_uuid) -> uuid    after login & validate, create or load their uuid
	init_client_uuid = function(client,generated_uuid) {
		return generated_uuid; //by default, just use a newly generated uuid
	}
	_on_invalid_packet = function(from) {
		if net_system.is_client(from) {
			client_kick(from,"Invalid packet!");
		}
	}
	
	#region default events
	
	//client asked to setup connection
	on(NET_EVENTS.connect_setup,function(dat,clientfrom){
		static info = { success: undefined, message: undefined, uuid: undefined };
		info.success = true;
		info.message = "";
		info.uuid = undefined;
		
		//check version
		var vers = dat[$ "version"];
		if !net_system.version_is_valid(vers) {
			info.success = false;
			info.message = "invalid version!";
			return info;
		}
		if !net_system.version_compatible(vers,NET_VERSION) {
			info.success = false;
			info.message = "client outdated!";
			return info;
		}
		
		//validate auth data
		var auth_data = dat[$ "auth"];
		var auth_info = validate_auth_data(auth_data);
		if !auth_info.success {
			info.success = false;
			info.message = auth_info.message;
			return info;
		}
		//store auth data
		clientfrom.auth_data = auth_data;
		
		//give them a uuid
		var _uuid = init_client_uuid(clientfrom,net_system.create_uuid(client_uuid_map));
		clientfrom.uuid = _uuid;	
		client_uuid_map[$ _uuid] = clientfrom;
		
		//uuid sent
		info.uuid = _uuid;
		return info;
		
	},false);
	
	//client sends first udp packet, get their port and finish connection
	on(NET_EVENTS.udp_setup,function(dat,clientfrom){
		
		var port = async_load[? "port"];
		var uuid = dat[$ "uuid"];
		if !net_system.uuid_is_valid(uuid) {
			//politely ask them to disconnect
			_helper_send_udp(socket_udp,async_load[? "ip"],port,NET_EVENTS.disconnected,{ reason: "invalid uuid!" },0);
			return;
		}
		
		clientfrom = client_get_by_uuid(uuid);
		if is_undefined(clientfrom) {
			net_log_warning($"Server received udp setup for missing client {uuid}!");
			return;
		}
		
		if is_undefined(clientfrom.port) {
			clientfrom.port = port;
			client_port_map[$ port] = clientfrom;
		}
		
		//get their ping
		clientfrom._ping_last = get_timer();
		request(clientfrom,NET_EVENTS.ping)
			.on_response(_on_ping_response);
		
		send(clientfrom,NET_EVENTS.udp_setup);
		
		//server-side, connection is complete
		on_client_connected(clientfrom);
	},false);
	
	on(NET_EVENTS.packet_failed,function(){
		stop();
		on_stopped("Packet failed!");
	},false);
	
	#endregion
	
	static _on_ping_response = function(data,from_client) {
		from_client.ping = ((get_timer() - from_client._ping_last)/1000);
		if NET_AUTOKICK_MAX_PING_MS>0 && from_client.ping>NET_AUTOKICK_MAX_PING_MS {
			client_kick(from_client,$"Maximum ping exceeded! {from_client.ping}/{NET_AUTOKICK_MAX_PING_MS}ms");
		}
	}
	
	///@desc opens the server for connections
	static start = function(_port=NET_PORT_DEFAULT,_max_clients=8) {
		
		port = _port;
		max_clients = _max_clients;
		net_system.set_timeout_connection_seconds(timeout_connect_seconds);
		
		var tsock = network_create_server(network_socket_tcp,port,max_clients);
		//var usock = network_create_server(network_socket_udp,port,max_clients);
		var usock = network_create_socket_ext(network_socket_udp,port);
		if tsock<0 || usock<0 {
			net_log_warning("server start failed!");
			stop();
			on_stopped("Server start failed!");
			return;
		}
		
		socket_tcp = tsock;
		socket_udp = usock;
		is_open = true;
		
		//ping clients
		net_system.destroy_time_source_safe(ts_ping);
		if track_ping {
			var _pingfunc = function(){
				clients_foreach(function(client){
					client._ping_last = get_timer();
				});
				var promise_arr = request(NET_ALL_CLIENTS,NET_EVENTS.ping);
				net_promise_on_each_response(promise_arr,_on_ping_response);
			};
			ts_ping = time_source_create(
				time_source_global,
				NET_PING_FREQUENCY_SECONDS,
				time_source_units_seconds,
				_pingfunc,[],-1
			);
			time_source_start(ts_ping);
			_pingfunc(); //call immediately
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
		net_system.destroy_time_source_safe(ts_ping);
		clients_clear();
		is_open = false;
	}
	///@desc start/stop broadcasting server info over LAN
	static broadcast_to_lan = function(state=true,_port=port_lan_broadcast) {
		net_system.destroy_time_source_safe(ts_lan_broadcast);
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
			ts_lan_broadcast = time_source_create(
				time_source_global,
				NET_LAN_BROADCAST_FREQUENCY_SECONDS,
				time_source_units_seconds,
				callback,[],-1
			);
			
			//start immediately
			callback();
			time_source_start(ts_lan_broadcast);
		}
	}
	
	#region client methods
	
	///@returns {Struct.net_client_struct} client
	static client_get_by_socket = function(sock) {
		return client_map[$ sock];
	}
	///@returns {Struct.net_client_struct} client
	static client_get_by_udp_port = function(port) {
		return client_port_map[$ port];
	}
	///@returns {Struct.net_client_struct} client
	static client_get_by_uuid = function(uuid) {
		return client_uuid_map[$ uuid];
	}
	///@param {Struct.net_client_struct} client
	static client_remove = function(client) {
		
		var sock = client.socket_tcp;
		if !variable_struct_exists(client_map,sock) return;
		
		var _uuid = client.get_uuid();
		if net_system.uuid_is_valid(_uuid) {
			variable_struct_remove(client_uuid_map,_uuid);
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
		
		client.obs_cleanup.call_arg(client);
	}
	///@param {Struct.net_client_struct} client
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
	static get_client_array = function() {
		return client_array;
	}
	static get_clients_filter = function(filter_func,_clientarr=undefined) {
		_clientarr ??= client_array;
		return array_filter(_clientarr,filter_func);
	}
	static get_clients_except = function(except_client,_clientarr=undefined) {
		static dat = { except_client: undefined };
		dat.except_client = except_client;
		return get_clients_filter(method(dat,function(client){
			return client != except_client;
		}),_clientarr);
	}
	static clients_clear = function() {
		array_foreach(client_array,function(client){
			client.obs_cleanup.call_arg(client);
		});
		clients_init();
	}
	///@param {Id.Socket} socket
	static client_create = function(sock) {
		
		var client = new net_client_struct(
			undefined, //uuid is created after auth
			sock,
			async_load[? "ip"]
		);
		
		client_map[$ sock] = client;
		array_push(client_array,client);
		
		client_count++
		
		return client;
	}
	
	#endregion
	
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
	
	#region send methods
	
	enum __net_server_send_type {
		_udp,
		_tcp,
		_req
	}
	
	///@desc send some type of data to some clients. if request, return a promise or array of promises.
	static _helper_server_send = function(
		to_client,
		filter_func=net_return_true,
		req_type=__net_server_send_type._tcp,
		type,
		data=undefined
	) {
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
			if !to_client.is_connected() {
				return undefined;
			}
			if !filter_func(to_client) {
				return undefined;
			}
			if req_type==__net_server_send_type._udp {
				_helper_send_udp(socket_udp,to_client.ip,to_client.port,type,data);
			}
			else if req_type==__net_server_send_type._tcp {
				_helper_send_tcp(to_client.socket_tcp,type,data);
			}
			else if req_type==__net_server_send_type._req {
				return _helper_request(to_client.socket_tcp,type,data);
			}
		}
		return undefined;
	}
	
	///@desc send data to: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	static send = function(to_client,type,data=undefined,filter_func=net_return_true) {
		_helper_server_send(to_client,filter_func,__net_server_send_type._tcp,type,data);
	}
	///@desc send UDP data to: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	static send_udp = function(to_client,type,data=undefined,filter_func=net_return_true) {
		_helper_server_send(to_client,filter_func,__net_server_send_type._udp,type,data);
	}
	///@desc send & request data from: (a client, an array of clients, or NET_ALL_CLIENTS), if filter_func returns true.
	///@returns {undefined | Struct.net_promise | Array<Struct.net_promise>} promises
	static request = function(to_client,type,data=undefined,filter_func=net_return_true) {
		return _helper_server_send(to_client,filter_func,__net_server_send_type._req,type,data);
	}
	
	#endregion
	
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
	port = undefined;
	is_connecting = false;
	is_connected = false;
	auth_data = undefined; // account or something
	
	uuid = undefined;
	
	serverfrom_value = "server"; // (value or function) what to pass in when receving a packet from the server
	
	ping = 0;
	_ping_last = undefined;
	track_ping = true; //whether to simply keep track of our ping to the server
	ts_ping = undefined;
	
	_on_invalid_packet = function() {
		//run_event(NET_EVENTS.disconnected,{ reason: "Invalid packet received!" }); //actually don't disconnect
	}
	_get_reply_socket = function() {
		return socket_tcp;
	};
	
	#region default events
	
	on(NET_EVENTS.connect_failed,function(reason){
		net_log_warning($"Client connect failed! {reason}");
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
	on(NET_EVENTS.connected,function(){
		net_system.destroy_time_source_safe(ts_ping);
		if track_ping {
			var _pingfunc = function(){
				_ping_last = get_timer();
				request(NET_EVENTS.ping)
				.on_response(function(){
					ping = ((get_timer()-_ping_last)/1000);
				});
			};
			ts_ping = time_source_create(
				time_source_global,
				NET_PING_FREQUENCY_SECONDS,
				time_source_units_seconds,
				_pingfunc,[],-1
			);
			time_source_start(ts_ping);
			_pingfunc(); //call immediately
		}
	},false);
	
	#endregion
	
	ts_udp_setup = undefined;
	udp_setup_tries = 0;
	udp_setup_max_tries = 5;
	//tries to send a first udp packet to the server, so the server has our udp port
	static _udp_setup_begin = function() {
		net_system.destroy_time_source_safe(ts_udp_setup);
		udp_setup_tries = 0;
		var callback = function(){
			send_udp(NET_EVENTS.udp_setup,{
				uuid
			});
			udp_setup_tries++
			if udp_setup_tries > udp_setup_max_tries {
				run_event(NET_EVENTS.disconnected);
			}
		};
		ts_udp_setup = time_source_create(time_source_global,2,time_source_units_seconds,callback,[],-1);
		
		on(NET_EVENTS.udp_setup,function(dat){
			net_system.destroy_time_source_safe(ts_udp_setup);
			
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
			net_log_warning("Client socket create failed!");
			run_event(NET_EVENTS.connect_failed,"Socket create failed!");
			return;
		}
		socket_tcp = tsock;
		socket_udp = usock;
		
		is_connected = false;
	}
	
	///@desc connect to a server
	static connect = function(_ip=NET_IP_DEFAULT,_port=NET_PORT_DEFAULT,_auth_data=undefined) {
		
		net_system.set_timeout_connection_seconds(timeout_connect_seconds);
		check_sockets();
		
		ip = _ip;
		port = _port;
		auth_data = _auth_data;
		
		is_connecting = true;
		
		var status = network_connect_async(socket_tcp, ip, port);
		if status < 0 {
			run_event(NET_EVENTS.connect_failed,"Unable to reach server!");
			return;
		}
	}
	static disconnect = function() {
		net_socket_close(socket_tcp);
		net_socket_close(socket_udp);
		net_system.destroy_time_source_safe(ts_udp_setup);
		net_system.destroy_time_source_safe(ts_ping);
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
					
					///@feather ignore GM1021
					var serverfrom = is_callable(serverfrom_value) ? serverfrom_value() : serverfrom_value;
					receive_packet(pack,serverfrom);
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
			version: NET_VERSION,
			auth: auth_data,
		})
		//server responds
		.on_response(function(response){
			if response.success {
				uuid = response.uuid; //get our uuid
				_udp_setup_begin();
			}
			else {
				net_log($"Connection refused: {response.message}");
				run_event(NET_EVENTS.connect_failed,response.message);
			}
		})
		.on_error(function(info){
			var type = info[$ "type"];
			net_log($"Connection failed: {type}");
			run_event(NET_EVENTS.connect_failed,type);
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

///@desc A server-side struct that holds data about a client
function net_client_struct(_uuid=undefined,socket=undefined,_ip=undefined) constructor {
	socket_tcp = socket;
	ip = _ip;
	port = undefined; //get from udp
	uuid = _uuid; //unique id
	ping = 0; //milliseconds
	_ping_last = 0;
	connected = true; //basically whether their tcp socket is connected
	auth_data = undefined; //account or something they connected with
	obs_cleanup = new net_observable(); //(client struct), called when destroyed
	
	static get_auth_data = function() {
		return auth_data;
	};
	static get_uuid = function() {
		return uuid;
	}
	static is_connected = function() {
		return connected;
	}
	static get_ping = function() {
		return ping;
	}
}

///@desc Listens for servers broadcasted over LAN and gets their info
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
				packet[$ "compatible"] = net_system.version_compatible(NET_VERSION,packet[$ "version"]);
				
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

#region utility

///@desc calls a function some time later
function net_callback(_period,_reps,_callback,_args=undefined) constructor {
	
	
	period = _period;
	reps = _reps;
	finished = false;
	onfinish = net_noop;
	
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
		net_system.destroy_time_source_safe(ts);
	}
	static finish = function() {
		
		cleanup();
		finished = true;
		onfinish();
		
	}
	
}

#region promises

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

#endregion

///@desc ok it's the same as a promise but whatever
function net_observable() constructor {
	listeners = [];
	listener_count = 0;
	
	///@param {Function} callback
	static listen = function(func) {
		array_push(listeners,func);
		listener_count++
		return self;
	}
	static has_listeners = function() {
		return listener_count>0;
	}
	
	static call = function(args=undefined) {
		static _emptyarr = [];
		args ??= _emptyarr;
		if !is_array(args) show_error("Observable must be given an argument array!",true);
		var i = 0;
		repeat(listener_count) {
			method_call(listeners[i++],args);
		}
	}
	///@desc call with a single argument
	static call_arg = function(arg=undefined) {
		static _args = [undefined];
		_args[0] = arg;
		
		var i = 0;
		repeat(listener_count) {
			method_call(listeners[i++],_args);
		}
	}
}

#endregion

#region useful

function net_noop(){}
function net_return_true(){ return true; }

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
	if net_system.is_socket(sock) {
		network_destroy(sock);
	}
}


function net_log(val) {
	val = string(val);
	val = window_get_caption() + "> " + val;
	show_debug_message(val);
}
#macro net_log_warning net_log

#endregion




