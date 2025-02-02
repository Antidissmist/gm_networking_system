



action_log = ds_list_create();
log_action = function(str) {
	ds_list_add(action_log,str);
	var len = ds_list_size(action_log);
	if len>30 {
		ds_list_delete(action_log,0);
	}
}


ImGui.__Initialize();


lan_listener = new net_lan_listener();


//position windows side by side
var winwid = window_get_width();
var winhei = window_get_height();
var dispwid = display_get_width();
var disphei = display_get_height();
var centerx = dispwid/2;
var centery = disphei/2;

var winx = 0;
var winy = 0;

if MultiClientGetID()==0 {
	winx = centerx-dispwid/4-winwid/2;
	winy = centery-winhei/2;
}
else {
	winx = centerx+dispwid/4-winwid/2;
	winy = /*centery-winhei/2 +*/ 100 + (MultiClientGetID()-1)*100;
}
window_set_position(winx,winy);

