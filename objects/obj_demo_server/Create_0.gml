

window_set_caption($"{MultiClientGetID()}: SERVER");


server = new net_server();
server.start();

server.broadcast_to_lan();

server.on_client_connected = function(client) {
	log("client connected!");
};
server.on_client_disconnected = function(client) {
	log("client disconnected.");
};

server.get_lan_server_info = function() {
	return {
		server_name: "my server"
	};
};



server.on("test_data",function(data,from_client){
	log($"received {data} from client {from_client.uuid}");
});

server.on("req_test",function(data,from_client){
	
	log($"client requesting {data.type}");
	
	if data.type=="money" {
		return 100;	
	}
	
	return 0;
});


letter_x = x+20;
letter_y = y;
letter_to_x = room_width/2+100;
letter_to_y = -20;
letter_from_x = room_width/2-100;
letter_from_y = -20;

server.on(NET_EVENTS.any,function(data){
	create_letter(letter_to_x,letter_to_y,x,y);
});

imgui_step = function() {
	ImGui.Text("---server---");
	
	ImGui.Text($"open: {server.is_open}");
	
	
	if server.is_open {
		if ImGui.Button("hello all") {
			server.send(NET_ALL_CLIENTS,"hello",{ message: "world!" });
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
	
		if server.client_count > 0 {
			if ImGui.Button("request first client") {
			
				var first_client = server.client_array[0];
			
				server.request(first_client,"test_request")
				.on_response(function(data,from){
					log($"request response: {data}");
				})
			
				create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
			}
		
			if ImGui.Button("request all") {
			
				var promise_arr = server.request(NET_ALL_CLIENTS,"test_request");
				//can't dot access an array so we have these functions
				net_promise_on_each_response(promise_arr,function(data,from_client){
					log($"request response: {data}");
				});
				net_promise_on_each_error(promise_arr,function(){
					//
				});
				net_promise_on_each_finally(promise_arr,function(){
					//
				})
			
				create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
			
			}
		
		}
	
	}
	else {
		if ImGui.Button("start server") {
			server.start();
		}
	}
	
	if ImGui.Button("destroy server") {
		instance_destroy(); //stops in cleanup event
	}
	
	
	server.clients_foreach(function(client,index){
		ImGui.Text($"---client---");
		ImGui.Text($"uuid: {client.uuid}");
		ImGui.Text($"connected: {client.connected}");
		ImGui.Text($"ping: {client.ping}ms");
		
		if ImGui.Button($"hello client {index}") {
			server.send(client,"hello",{ message: $"client {index}" });
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
		
	});
	
}

