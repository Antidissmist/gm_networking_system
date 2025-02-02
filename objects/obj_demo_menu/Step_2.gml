



ImGui.SetNextWindowSize(200,window_get_height());
ImGui.SetNextWindowPos(0,0);
var winflags = 0
| ImGuiWindowFlags.NoTitleBar
| ImGuiWindowFlags.NoResize
| ImGuiWindowFlags.NoMove
//| ImGuiWindowFlags.NoBackground
//| ImGuiWindowFlags.AlwaysAutoResize

		
var ret = ImGui.Begin("debug menu", true, winflags, ImGuiReturnMask.Both);

if (ret & ImGuiReturnMask.Return) {
		
	ImGui.Text("Debug menu");
	
	
	if !instance_exists(obj_demo_server) && !instance_exists(obj_demo_client) {
		if ImGui.Button("create server object") {
			instance_create_depth(room_width/2,room_height/2,0,obj_demo_server);
			select_client_server = false;
		}
		if ImGui.Button("create client object") {
			instance_create_depth(room_width/2,room_height/2,0,obj_demo_client);
			select_client_server = false;
		}
		
		
		ImGui.Text("games on LAN:");
		ImGui.Text(json_stringify(lan_listener.server_array,true));
		
	}
	else {
		with obj_demo_server { imgui_step(); }
		with obj_demo_client { imgui_step(); }
	}
	
	
	ImGui.End();
}




///action log
var wid = 300;
var hei = window_get_height();
ImGui.SetNextWindowPos(window_get_width()-wid,0);
ImGui.SetNextWindowSize(wid,hei);
var winflags = 0
| ImGuiWindowFlags.NoTitleBar
| ImGuiWindowFlags.NoResize
| ImGuiWindowFlags.NoMove
var ret = ImGui.Begin("action log", true, winflags, ImGuiReturnMask.Both);
	
if (ret & ImGuiReturnMask.Return) {
	
	var len = ds_list_size(action_log);
	for(var i=0; i<len; i++) {
		ImGui.Text(action_log[| i]);
	}
	
	
	ImGui.End();
}





