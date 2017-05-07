# -*-perl-*-
###################################################################################################
#
#       ConfigurationBackup.pm
#       Date:       1st May 2017
#
#       Version:    0.01
#       Date:       2nd May 2017
#
###################################################################################################

package test;

use strict;
use warnings;

use Common::Log;
use genConfig::Utils;
use genConfig::File;
use genConfig::SNMP;

### Start package init

use genConfig::Plugin;

# SSH and Telnet Library
use Net::OpenSSH;
use Net::Telnet;
use Switch;
use File::Copy qw(move);

our @ISA = qw(genConfig::Plugin);

my $VERSION   = 0.00;
my $ATLAS_Ver = 0.00;


########################################################################
# It mapped from oid to backup functions
# https://www.iana.org/assignments/enterprise-numbers/enterprise-numbers
# vendor oid can be looked up from the URL
# OID prefix must starts with .1.3.6.1.4.1
# Also need to match the longest prefix
########################################################################
my %oid_method = (
    '.1.3.6.1.4.1.9'    => 'Cisco',
    '.1.3.6.1.4.1.2011' => 'Huawei',
    '.1.3.6.1.4.1.2636' => 'Juniper',
);

my %defined_backup_func = (
    Cisco   => \&backup_Cisco,
    Juniper => \&backup_Juniper,
    Huawei  => \&backup_Huawei,
);

my %defined_device = (
    '1.1.1.1' => [ 'Cisco',   'telnet' ],
    '2.2.2.2' => [ 'Juniper', 'ssh' ],
);

my %defined_credential = (
    '1.1.1.1' => [ 'root', 'root' ],
    '2.2.2.2' => [ 'root', 'root' ],
);

########################################################################
# We don't need any of other method to build target file.
# In order to not block other plugins, we have 2 choices:
# 1. using a thread to run backup task at beginning <can_handle>
# and wait it finish at ending <custom_files>
# 2. running backup task at ending
#
# func<can_handle> is called first in genConfig.pl
# func<custom_files> is called last in genConfig.pl
########################################################################
my %backup_conf = (
    use_thread      => 0,
    working_thread  => undef,
    backup_func     => undef,
    backup_ip       => undef,
    backup_protocol => undef,
    backup_auth     => {
        user     => undef,
        password => undef,
    },
    backup_file   => undef,
    session       => undef,
    configuration => undef,
);

#Dynamic load threads according to backup_conf
require threads if $backup_conf{use_thread};

### End package init

###############################################################################
# These are device types we can handle in this plugin
# the names should be contained in the sysdescr string
# returned by the devices. The name is a regular expression.
###############################################################################
my @types = keys %defined_backup_func;

###############################################################################
### Private variables
###############################################################################

my $script = "Configurate Backup Module";
###############################################################################

#-------------------------------------------------------------------------------
# plugin_name
# IN :
# OUT: returns the plugin name defined in $script
#-------------------------------------------------------------------------------

sub plugin_name {
    my $self = shift;
    return $script;
}

#-------------------------------------------------------------------------------
# device_types
# IN : N/A
# OUT: returns an array ref of devices this plugin can handle
#-------------------------------------------------------------------------------

sub device_types {
    my $self = shift;
    return \@types;
}

#-------------------------------------------------------------------------------
# can_handle
# IN : opts reference
# OUT: returns a true if the device can be handled by this plugin
#-------------------------------------------------------------------------------

sub can_handle {
    my ( $self, $opts ) = @_;

    #Build %backup_conf
    $backup_conf{backup_ip}   = $opts->{ip};
    $backup_conf{backup_file} = $opts->{outputdir} . '/configuration';
    my @credential = @{ $defined_credential{ $opts->{ip} } };
    $backup_conf{backup_auth}{user}     = $credential[0];
    $backup_conf{backup_auth}{password} = $credential[1];
    if ( $defined_device{ $backup_conf{backup_ip} } ) {

        # Predefined Devices, [0]=>device_type, [1]=>protocol
        my @device = @{ $defined_device{ $opts->{ip} } };
        $backup_conf{backup_func}     = $defined_backup_func{ $device[0] };
        $backup_conf{backup_protocol} = $device[1];
    }
    else {
        my @oids = keys %oid_method;

        # Find longest oid match
        my ($oid) = sort { length $b <=> length $a }
            grep { 0 == index $opts->{sysObjectID}, $_ } @oids;
        if ($oid) {
            $backup_conf{backup_func}
                = $defined_backup_func{ $oid_method{$oid} };
        }
        else {
            Common::Log::Error(
                "No defined backup method for this device: $opts->{sysObjectID}"
            );
            return 0;
        }
    }

    #start a thread if use_thread
    $backup_conf{working_thread}
        = threads->create( $backup_conf{backup_func} )
        if $backup_conf{use_thread};

    return 1;
}

sub custom_files {

    # Wait thread finish
    if ( $backup_conf{use_thread} ) {
        Info("Waiting backup thread finish ...");
        $backup_conf{configuration} = $backup_conf{working_thread}->join();
    }
    else {
        $backup_conf{configuration} = $backup_conf{backup_func}();
    }
    Info("Backup Done");

    if ( -e $backup_conf{backup_file} ) {
        Info("Find existing backup configuration, move to configuration.bak");
        move( $backup_conf{backup_file}, $backup_conf{backup_file} . '.bak' );
    }
    Info("Writing into $backup_conf{backup_file} ...");
    open( my $fh, '>', $backup_conf{backup_file} )
        or die("Failed to write to backup file");
    print $fh, $backup_conf{configuration};
    close $fh;
    Info("Writing Done");
}

#---------------------------------------------------
# Setup Session and a generic cmd func
# Telenet works in an interactive mode
# However, SSH commands works in a seperate exec pipe
#---------------------------------------------------
sub setupSession {
    switch ( $backup_conf{backup_protocol} ) {
        my $user     = $backup_conf{backup_auth}{user};
        my $password = $backup_conf{backup_auth}{password};
        my $host     = $backup_conf{backup_ip};
        case 'SSH' {
            $backup_conf{session}
                = Net::OpenSSH->new("$user:$password\@$host");
        }
        case 'Telnet' {
            $backup_conf{session} = Net::Telnet->new();
            $backup_conf{session}->open( $backup_conf{backup_ip} );
            $backup_conf{session}->login( $backup_conf{back} );
        }
        else {
            Common::Log::Error("Unspported Protol!");
            die("Unspported Protol!");
        }

    }
}

sub cmd {
    switch ( $backup_conf{backup_protocol} ) {
        case 'SSH'    { return $backup_conf{session}->capture(@_); }
        case 'Telnet' { return $backup_conf{session}->cmd(@_); }
    }
}

sub shutdownSession {
    switch ( $backup_conf{backup_protocol} ) {
        case 'SSH'    { $backup_conf{session}->disconnect(1); }
        case 'Telnet' { $backup_conf{session}->close(); }
    }

}

#---------------------------------------------------
# Methods to backup different devices from different vendors
# subroutine name should be like this:
# backup_<vendor>_<device_type>
# All theses backup methods have a copy of backup_conf,
# which contains all target values.
#---------------------------------------------------
sub backup_Cisco {
    $backup_conf{backup_protocol} = 'SSH'
        unless $backup_conf{backup_protocol};    # Default protocols
    Info(
        "Start backup_Cisco @ $backup_conf{backup_ip} using $backup_conf{backup_protocol}"
    );
    setupSession();
    if ( $backup_conf{backup_protocol} eq 'Telnet' ) {

        # For Telnet, no page break for configuration
        cmd("terminal width 0");
        cmd("terminal length 0");
    }
    my $output = cmd("show running");
    shutdownSession();
    return $output;
}

sub backup_Juniper {
    $backup_conf{backup_protocol} = 'SSH'
        unless $backup_conf{backup_protocol};
    Info(
        "Start backup_Juniper @ $backup_conf{backup_ip} using $backup_conf{backup_protocol}"
    );
    setupSession();
    my $output = cmd('show configuration | no-more');
    shutdownSession();
    return $output;
}

sub backup_Huawei {
    $backup_conf{backup_protocol} = 'SSH'
        unless $backup_conf{backup_protocol};
    Info(
        "Start backup_Huawei @ $backup_conf{backup_ip} using $backup_conf{backup_protocol}"
    );
    setupSession();
    my $output = cmd('display current-configuration');
    shutdownSession();
    return $output;

}

1;
