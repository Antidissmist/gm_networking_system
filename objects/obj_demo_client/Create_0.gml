

window_set_caption($"{MultiClientGetID()}: CLIENT");


client = new net_client();

client.connect("127.0.0.1");


client.on(NET_EVENTS.disconnected,function(){
	log("client disconnected");
});

client.on("hello",function(data,from){
	log($"received: hello {data.message}");
});

client.on("test_request",function(data,from){
	return "ok thanks";
});




letter_x = x+20;
letter_y = y;
letter_to_x = room_width/2+100;
letter_to_y = -20;
letter_from_x = room_width/2-100;
letter_from_y = -20;


client.on(NET_EVENTS.any,function(data){
	create_letter(letter_to_x,letter_to_y,x,y);
});


imgui_step = function() {
	ImGui.Text("client");
	
	ImGui.Text($"connected: {client.is_connected}");
	
	if client.is_connected {
		if ImGui.Button("send tcp") {
			client.send_udp("test_data",{ things: 100, stuff: [1,5,2,3,4] });
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
		if ImGui.Button("send udp") {
			client.send_udp("test_data",{ things: 100, stuff: [1,5,2,3,4] });
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
		if ImGui.Button("request") {
		
			client.request("req_test",{ type: "money" })
			.on_response(function(data){
				log($"requested {data} money from server");
			})
		
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
		if ImGui.Button("request (timeout)") {
		
			client.request("something random")
			.on_response(function(){
				//never responds
			})
			//times out after a few seconds
			.on_error(function(data){
				log($"request error! type: {data.type}");
			})
			.on_finally(function(){
				//called after either response or error
			})
		
			create_letter(letter_x,letter_y,letter_to_x,letter_to_y);
		}
	}
	else {
		if ImGui.Button("connect") {
			client.connect("127.0.0.1");
		}
	}
	
	if ImGui.Button("destroy client") {
		instance_destroy(); //stops in cleanup event
	}
	
	
}

