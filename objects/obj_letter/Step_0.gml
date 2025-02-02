


var lsp = 0.2;
x = lerp(x,targx,lsp);
y = lerp(y,targy,lsp);
if point_distance(x,y,targx,targy)<1 {
	shrink = true;
}


if shrink {
	image_xscale = lerp(image_xscale,0,.2);
	image_yscale = image_xscale;
	image_angle += 10;
	if image_xscale<0.01 {
		instance_destroy();
	}
}

