#! /usr/bin/perl -w
#
# UsersRoutines module
#


package UsersRoutines;

use strict;

use ycp;

our %TYPEINFO;

 
##------------------------------------
##------------------- global imports

YaST::YCP::Import ("SCR");

##-------------------------------------------------------------------------
##----------------- directory manipulation routines -----------------------

##------------------------------------
# Create home directory
# @param skeleton skeleton directory for new home
# @param home name of new home directory
# @return success
BEGIN { $TYPEINFO{CreateHome} = ["function",
    "boolean",
    "string", "string"];
}
sub CreateHome {

    my $skel	= $_[0];
    my $home	= $_[1];
    
    # create a path to new home directory, if not exists
    my $home_path = substr ($home, 0, rindex ($home, "/"));
    if (!%{SCR::Read (".target.stat", $home_path)}) {
	SCR::Execute (".target.mkdir", $home_path);
    }

    # if skeleton does not exist, do not copy it
    if (!%{SCR::Read (".target.stat", $skel)}) {
	if (! SCR::Execute (".target.mkdir", $home)) {
	    y2error ("error creating $home");
	    return 0;
	}
    }
    # now copy homedir from skeleton
    else {
	my $command	= "/bin/cp -r $skel $home";
	my %out		= %{SCR::Execute (".target.bash_output", $command)};
	if (($out{"stderr"} || "") ne "") {
	    y2error ("error calling $command: ", $out{"stderr"} || "");
	    return 0;
	}
    }
    y2milestone ("The directory $home was successfully created.");
    return 1;
}

##------------------------------------
# Change ownership of directory
# @param uid UID of new owner
# @param gid GID of new owner's default group
# @param home name of new home directory
# @return success
BEGIN { $TYPEINFO{ChownHome} = ["function",
    "boolean",
    "integer", "integer", "string"];
}
sub ChownHome {

    my $uid	= $_[0];
    my $gid	= $_[1];
    my $home	= $_[2];

    my %stat	= %{SCR::Read (".target.stat", $home)};
    if (!%stat) {
	#no such directory
	return 1;
    }

    if (($uid == ($stat{"uid"} || -1)) && ($gid == ($stat{"gid"} || -1))) {
	# directory already exists and chown is not needed
	return 1;
    }

    my $command = "/bin/chown -R $uid:$gid $home";
    my %out	= %{SCR::Execute (".target.bash_output", $command)};
    if (($out{"stderr"} || "") ne "") {
	y2error ("error calling $command: ", $out{"stderr"} || "");
	return 0;
    }
    y2milestone ("Owner of files in $home changed to user with UID $uid");
    return 1;
}

##------------------------------------
# Move the directory
# @param org_home original name of directory
# @param home name of new home directory
# @return success
BEGIN { $TYPEINFO{MoveHome} = ["function",
    "boolean",
    "string", "string"];
}
sub MoveHome {

    my $org_home	= $_[0];
    my $home		= $_[1];

    # create a path to new home directory, if it not exists
    my $home_path = substr ($home, 0, rindex ($home, "/"));
    if (!%{SCR::Read (".target.stat", $home_path)}) {
	SCR::Execute (".target.mkdir", $home_path);
    }

    my $command = "/bin/mv $org_home $home";
    my %out	= %{SCR::Execute (".target.bash_output", $command)};
    if (($out{"stderr"} || "") ne "") {
	y2error ("error calling $command: ", $out{"stderr"} || "");
	return 0;
    }
    y2milestone ("The directory $org_home was successfully moved to $home");
    return 1;
}

##------------------------------------
# Delete the directory
# @param home name of directory
# @return success
BEGIN { $TYPEINFO{DeleteHome} = ["function", "boolean", "string"];}
sub DeleteHome {

    my $home		= $_[0];

    my $command	= "/bin/rm -rf $home";
    my %out	= %{SCR::Execute (".target.bash_output", $command)};
    if (($out{"stderr"} || "") ne "") {
	y2error ("error calling $command: ", $out{"stderr"} || "");
	return 0;
    }
    y2milestone ("The directory $home was succesfully deleted");
    return 1;
}

1
# EOF
