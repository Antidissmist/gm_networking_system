# GM networking system v1.0.0

TCP. UDP. You want it? It's your my friend. As long as you have enough bandwidth.

This system is intended to simplify netcode in GameMaker as much as possible, so I never have to rewrite my netcode again. 

Made in GameMaker v2024.6.1.208, so should be compatible with modern versions.

## Quick Setup

### server-side:
```js
//create event
server = new net_server(port,max_players);
server.start();

server.on("hello",function(data,from_client){
    show_debug_message("hello, " + data.message); //hello, world!
});

//async networking event
server.on_async_networking();
//cleanup event
server.cleanup();
```

### client-side:
```js
//create event
client = new net_client();
client.connect(ip,port);

client.send("hello",{ message: "world!" });

//async networking event
client.on_async_networking();
//cleanup event
client.cleanup();
```

## Features


```js
//send data (TCP)
server.send(client,"event",data);
client.send("event",data);

//send data (UDP)
server.send_udp(client,"event",data);
client.send_udp("event",data);

//send to all clients, given a condition
server.send(NET_ALL_CLIENTS,"event",data,filter_function);

//request data and get a response
server.request(client,"event")
    .on_response(function(response,from_client){ })
    //optional:
    .on_error(function(data){ }) //data: { type: "timeout" }
    .on_finally(function(){ })
client.request("event") //same as above
    .on_response(function(){ })

//close connection
server.stop();
client.disconnect();
```
You can send anything JSON-able like a struct, array or just a value.

Broadcast over LAN:
```js
//server create event:
server.get_lan_server_info = function() {
    //add any relevant info like name, number of players, etc.
    return { name: "cool server" };
};
//anywhere:
server.broadcast_to_lan(true); //starts broadcasting server ip & info over LAN
```
Client-side (in like a multiplayer menu) look for LAN games to join:
```js
//create event:
listener = new net_lan_listener();
//async networking event:
listener.on_async_networking();
//cleanup event:
listener.cleanup();

/*
At some point listener.server_array will look something like this:
[
    {
        ip: "127.0.0.1",
        server_port: 6510,
        compatible: true,
        version: 1,
        info: { name: "cool server" }
    },
    etc...
]
*/
```
Some more things to know about:
```js
server_or_client.on(NET_EVENTS.packet_failed); //sending a packet failed multiple times, maybe quit to menu
//client:
client.on(NET_EVENTS.connected,func); //we can start sending gameplay related stuff
client.on(NET_EVENTS.disconnected,func); //lost connection or kicked, quit to menu
client.on(NET_EVENTS.connect_failed,func); //failed trying to connect to server, quit to menu?
client.is_connected //boolean
client.is_connecting //bolean; "waiting for server..."
client.uuid //a unique string you can tell clients apart with.
//server methods:
server.on_client_connected = function(client){}; //"player joined the game!"
server.on_client_disconnected = function(client){}; //"player left the game!"
server.is_open //boolean
server.clients_foreach(function(client,index){});
server.client_kick(client,reason_string);
```


Find a bug? let me know! ok bye

