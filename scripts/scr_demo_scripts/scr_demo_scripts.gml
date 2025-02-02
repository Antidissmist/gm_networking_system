


function log(str) {
	obj_demo_menu.log_action(str);
}


function create_letter(xfrom,yfrom,xto,yto) {
	instance_create_depth(xfrom,yfrom,-5,obj_letter,{ targx: xto, targy: yto });
}

