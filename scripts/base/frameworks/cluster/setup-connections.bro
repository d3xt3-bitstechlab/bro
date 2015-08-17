##! This script establishes communication among all nodes in a cluster
##! as defined by :bro:id:`Cluster::nodes`.

@load ./main
@load base/frameworks/communication
@load base/frameworks/cluster

@if ( Cluster::node in Cluster::nodes )

module Cluster;

function process_node(name: string)
	{
	local n = nodes[name];
	local me = nodes[node];

	# Connections from the control node for runtime control
	# Every node in a cluster is eligible for control from this host.
	if ( CONTROL in n$node_roles )
		Communication::nodes["control"] = [$host=n$ip, $zone_id=n$zone_id,
		                                   $connect=F, $class="control"];

	if ( MANAGER in me$node_roles )
		process_node_manager(name);
	else if ( DATANODE in me$node_roles )
		process_node_datanode(name);
	else if ( WORKER in me$node_roles )
		process_node_worker(name);
	}

function process_node_manager(name: string)
	{
	local n = nodes[name];
	local me = nodes[node];
	if ( WORKER in n$node_roles && n$manager == node )
		Communication::nodes[name] = [$host=n$ip, 
																	$zone_id=n$zone_id, 
																	$p=n$p,
																	$connect=F,
		     													$class=name, 
																	$request_logs=T];
			
	if ( DATANODE in n$node_roles && n$manager == node )
		Communication::nodes[name] = [$host=n$ip, 
																	$zone_id=n$zone_id, 
																	$p=n$p,
																	$connect=F,
		     													$class=name, 
																	$request_logs=T];
				
	if ( TIME_MACHINE in n$node_roles && me?$time_machine && me$time_machine == name )
		Communication::nodes["time-machine"] = [$host=nodes[name]$ip,
		                                        $zone_id=nodes[name]$zone_id,
		                                        $p=nodes[name]$p,
		                                        $connect=T, 
																						$retry=1min];
	}

function process_node_datanode(name: string)
	{
	local n = nodes[name];
	local me = nodes[node];

	if ( WORKER in n$node_roles && n$datanode == node )
		Communication::nodes[name] = [$host=n$ip, 
																	$zone_id=n$zone_id, 
																	$p=n$p, 
																	$connect=F, 
																	$class=name];
		
	# accepts connections from the previous one. 
	# FIXME: Once we're using multiple proxies, we should also figure out some $class scheme ...
	if ( DATANODE in n$node_roles )
		{
		if ( n?$datanode)
			Communication::nodes[name] = [$host=n$ip, 
																		$zone_id=n$zone_id, 
																		$p=n$p, 
																		$connect=T, 
																		$retry=1mins];

		else if ( me?$datanode && me$datanode == name )
			Communication::nodes[me$datanode] = [	$host=nodes[name]$ip, 
																						$zone_id=nodes[name]$zone_id,
																						$p=nodes[name]$p, 
																						$connect=F];
		}
			
	# Finally the manager, to send status updates to.
	if ( MANAGER in n$node_roles )
		{
		if ( me$manager == name)
		# name = manager 
		Communication::nodes[name] = [$host=nodes[name]$ip, 
	                               $zone_id=nodes[name]$zone_id, 
	                               $p=nodes[name]$p, 
	                               $connect=T, $retry=1mins, 
	                               $class=node];

		else
			delete Communication::nodes[name];
		}
	}

function process_node_worker(name: string)
	{
	local n = nodes[name]; # the remote node
	local me = nodes[node]; # the local node

	if ( MANAGER in n$node_roles )
		{
		if ( me$manager == name )
			# name = manager 
			Communication::nodes[name] = [$host=nodes[name]$ip, 
		 	                          		$zone_id=nodes[name]$zone_id,
		  	                         		$p=nodes[name]$p,
		    	                       		$connect=T, 
																		$retry=1mins, 
		      	                     		$class=node];

		else
			delete Communication::nodes[name];
		}

	if ( DATANODE in n$node_roles )
		{
		if ( me$datanode == name )
			# name = datanode 
			Communication::nodes[name] = [$host=nodes[name]$ip, 
			                           		$zone_id=nodes[name]$zone_id,
			                           		$p=nodes[name]$p,
		  	                         		$connect=T, 
																		$retry=1mins, 
		    	                       		$class=node];
		else
			delete Communication::nodes[name];
		}		

	if ( TIME_MACHINE in n$node_roles  )
		{
		if(me?$time_machine && me$time_machine == name)
			Communication::nodes["time-machine"] = [$host=nodes[name]$ip, 
		 	                                       	$zone_id=nodes[name]$zone_id,
		  	                                      $p=nodes[name]$p,
		    	                                    $connect=T, 
		      	                                  $retry=1min];
		else
			delete Communication::nodes[name];
		}
	}

event Cluster::update_cluster_node(name: string, roles: set[string], ip: string, zone_id: string, p: string, interface: string, manager: string, workers: set[string], datanode: string)
	{
	# Build the Node entry for the new/updated node
	local new_node = Node($node_roles=get_roles_enum(roles),
												$ip = to_addr(ip),
												$zone_id = zone_id,
												$interface = interface,
												$p = to_port(p),
												$manager = manager,
												$workers = workers,
												$datanode = datanode);

	local lnode = nodes[node];
	local set_roles = F;
	local update_connections = F;
	if( name == node ) # This is an update for us
		{
		print " * Local node received an update from control";
		if(enum_set_eq(new_node$node_roles, lnode$node_roles))
			set_roles = T;

		if( new_node?$datanode != lnode?$datanode
				|| new_node$datanode != lnode$datanode )
			update_connections = T;

		if( new_node?$workers != lnode?$workers
				|| !string_set_eq(new_node$workers, lnode$workers) ) 
			update_connections = T;

		if( new_node?$manager != lnode ?$ manager
				|| new_node$manager != lnode$manager )
			update_connections = T;
		}
	else if (name in nodes ) # This is an update for another node
		{
		print " * We received an update for node ", name;
		update_connections = T;
		}
	else # New node
		{
		print " * Node ", name, " joined the cluster";
		update_connections = T;
		}

	# .. and store the entry in the node list
	Cluster::nodes[name] = new_node; 	
	print "new_node data? ", new_node$datanode;

	# Update node list and Communication::nodes
	for (n in nodes)
		process_node(n);

	if(set_roles)
		Cluster::set_local_roles(T);
	if(update_connections)
		event Cluster::node_updated(name);
}

event Cluster::remove_cluster_node(name: string)
	{
	print "remove node ", name;
	}

event bro_init() &priority=9
	{
	for ( name in nodes )
		process_node(name);
	}

@endif
