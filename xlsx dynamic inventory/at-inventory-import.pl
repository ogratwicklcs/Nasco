#!/usr/bin/perl -w
#******************************************************************************************
#   Owner: Andre Roland (aroland@br.ibm.com)
#	Create date: 01/Nov/2019
#	Version: 20.8
#	Import XLSX to Ansible tower import
#	-Requirements:
#	got to: https://github.ibm.com/cacf/inventory_load/
#
#	TODO:
#	Bugs: awx-manage inventory-import flattens group variables on hosts. Corrected on Ansible tower 3.3 https://access.redhat.com/solutions/3714731
#	Changes:
#	VERSION       DATE              MODIFIED BY
#	*******       ****             ************
#	20.5        11/MAY/2020        ankreddy@in.ibm.com 
#	     - Added support for 3 hops connection vars.
#	     - Added support for groups and hosts tab in different files
#	     - Added support for overwrite groups and hosts if already exists
#	     - Modified the script to support new groups tab format.
#
#	20.8        05/AUG/2020        ankreddy@in.ibm.com 
#	     - Added support for 4 and 5 hops connection vars.
#	     - Fixed a bug for windows where connection vars json for 3 or more hops was not working.
#******************************************************************************************
use warnings;

use lib './libs_inventory/';

use Getopt::Long;
use Text::CSV_XS;
use HTML::Entities; #so we can import Libbreoffice encoding
use Spreadsheet::XLSX;
use Data::Dumper;
use File::Temp;
use JSON;
use YAML;
use POSIX qw(strftime);
#for threading
use threads;
use threads::shared;
#use utf8;

#configurable parameters ###########################
$version="20.8";
$reportdb_file="importfile.xlsx"; #default name if nothing provided
$csv_hosts_suffix="hosts.csv";
$csv_groups_suffix="groups.csv";
$overwrite=0; #0 do not overwrite if host or groups alread exists, 1 overwrite group or host if exists.
$maxthreads = 20; #this is the number of parallel thread range 1 - Max number of connections tower can handle (To be discovered)
$header_row_hosts = 2; #Hosts TAB initial row. Excel starts in row 0 but sometimes there are extra rows that will be discarded
$bypass_namestandard_validation=0; #0:validates 1:bypass. Bypass may be used when a problem in the check is found (and imperative to upload inventory, use it wisely)
$force_credproxy_grp_definition=1; #0:bypass 1:forces credential and proxy groups to be present the GROUPS TAB (implies mandatory var creation too). When 0, allow them to be created without a group var just instantiating to the host in the HOSTS TAB.
our $debug_level=1; #1/2/3 to print more messages
#header columns names ONLY [a-Z], spaces and numbers. AVOID SPECIAL CHARACTERS
#$hosts_hostname_header=lc("Name");
$hosts_organization_header=lc("Organization");
$hosts_ip_header=lc("IPaddress");
$hosts_connectionaddress_header=lc("ConnectionAddress");
$hosts_fqdn_header=lc("FQDN");
$hosts_ostype_header=lc("OSTYPE");
$hosts_devicetype_header=lc("DeviceType");
$hosts_tier_header=lc("Tier");
$hosts_blacklisted_event_header=lc("Blacklist for Events");
$hosts_blacklisted_bigfix_header=lc("Blacklist for HC");
$hosts_blacklisted_patchscan_header=lc("Blacklist for Patchscan");
$hosts_access_event_header=lc("Access group for Event");
$hosts_access_bigfix_header=lc("Access group for HC");
$hosts_access_patchscan_header=lc("Access group for Patchscan");
$hosts_proxygroup_header=lc("ProxyGroup");
$hosts_credgroup_header=lc("CredentialGroup");
$hosts_groupmemberlist_header=lc("Membership List");
$hosts_hostvar_header=lc("Host Variables");
$hosts_middlewarevar_header=lc("Middleware Variables");
$hosts_action_header=lc("Action");
#Group category	Group name	Mandatory variables	Extra variables
$groups_category_header=lc("Group category");
$groups_name_header=lc("Group name");
$groups_mandatoryvars_header=lc("MANDATORY CREDENTIAL Variables");
$groups_extravars_header=lc("OPTIONAL variables");
$groups_mandatory_user_inputs_header=lc("Mandatory User Inputs");

$group_check_regex="test|dit|sit|uat|prod|Beta|Blacklist|DEVELOPMENT|DR|Dev|Integration|OTHER|PRE_DEVELOPMENT|PRE_PRODUCTION|PRE_TEST|PRODUCTION|QA|RECOVERY|Staging|TBD|TEST|UNKNOWN|NonProduction|preprod";
$supported_os_types="AIX|ASYNCOS|CatOS|Cisco ACE|Cisco ASA|EMC Flare|FIRMWARE|HP-UX|HYPERVISOR|IOS|JunS|LINUX|MAC OS|MS\/DOS|MVS|NETWARE|NTAP|NX-OS|Network|OIS|OS\/2|OS\/390|OS400|Other|POS|RTOS|SAN\/NAS|SOLARIS|ScreenOS|Solaris|TMOS|UCOS|UNIX|UNKNOWN|VM\/ESA|VME|VMS|VMware|VOS|VSE|WIN|Windows|Xen|Z\/OS|Z\/TPF|i5\/OS";

$supported_os_groups="grp_aix|grp_asyncos|grp_catos|grp_cisco_ace|grp_cisco_asa|grp_emc_flare|grp_firmware|grp_hp_ux|grp_hypervisor|grp_ios|grp_juns|grp_linux|grp_mac_os|grp_ms_dos|grp_mvs|grp_netware|grp_ntap|grp_nx_os|grp_network|grp_ois|grp_os_2|grp_os_390|grp_os400|grp_other|grp_pos|grp_rtos|grp_san|grp_solaris|grp_screenos|grp_solaris|grp_tmos|grp_ucos|grp_unknown|grp_unix|grp_unknown|grp_vm_esa|grp_vme|grp_vms|grp_vmware|grp_vmware|grp_vos|grp_vse|grp_win|grp_windows|grp_xen|grp_z_os|grp_z_tpf|grp_i5_os|grp_nas";

$supported_device_types="Appliance|Application Switch|Chassis|Compute|Cloud|Concentrator|Container|Firewall|Gateway|Hypervisor|Module|Network|PC|Power|Router|SAN Switch|SAN/NAS|Server|Storage|StorageElement|Switch|VoiceGateway|VoiceMail|Wireless|_Other_";
my $stamp = strftime "%Y%d%b%H%M%S%Y", localtime;
#Error arrays
my @invalid_ips;
my @not_defined_fqdn;
my @invalid_device_types;
my @decomm_hosts;
my @invalid_tiers;
my @invalid_ostypes;
my @host_create_errors :shared;
my @hosts_skipped :shared;
########################
#Socks configuration for different hops
my $one_hop =q(ansible_psrp_protocol: 'http',ansible_psrp_proxy: 'socks5h://unixsocket/tmp/mysocks-{{ account_code }}-{{ trans_num }}-{{ jh_socks_port }}',ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand='ssh -W %h:%p {{ jh1_ssh_user }}@{{ jh1_ip }} -i $JH1_SSH_PRIVATE_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'');

my $two_hop=q(ansible_psrp_protocol: 'http',ansible_psrp_proxy: 'socks5h://unixsocket/tmp/mysocks-{{ account_code }}-{{ trans_num }}-{{ jh_socks_port }}',ansible_ssh_common_args: '-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='ssh -i $JH2_SSH_PRIVATE_KEY -W %h:%p -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'ssh -i $JH1_SSH_PRIVATE_KEY -W {{ jh2_ip }}:{{ jh2_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null {{ jh1_ssh_user }}@{{ jh1_ip }}'"'"' {{ jh2_ssh_user }}@{{ jh2_ip }}'');

my $three_hop=q(ansible_psrp_protocol: 'http',ansible_psrp_proxy: 'socks5h://unixsocket/tmp/mysocks-{{ account_code }}-{{ trans_num }}-{{ jh_socks_port }}',ansible_ssh_common_args: '-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='ssh -i $JH3_SSH_PRIVATE_KEY -W %h:%p -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'ssh -i $JH2_SSH_PRIVATE_KEY -W {{ jh3_ip }}:{{ jh3_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'ssh -i $JH1_SSH_PRIVATE_KEY -W {{ jh2_ip }}:{{ jh2_ssh_port }} -m hmac-sha1 -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null {{ jh1_ssh_user }}@{{ jh1_ip }}'"'"'"'"'"'"'"'"' {{ jh2_ssh_user }}@{{ jh2_ip }}'"'"' {{ jh3_ssh_user }}@{{ jh3_ip }}'');

my $four_hop=q(ansible_psrp_protocol: 'http',ansible_psrp_proxy: 'socks5h://unixsocket/tmp/mysocks-{{ account_code }}-{{ trans_num }}-{{ jh_socks_port }}',ansible_ssh_common_args: '-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='ssh -i $JH4_SSH_PRIVATE_KEY -W %h:%p -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'ssh -i $JH3_SSH_PRIVATE_KEY -W {{ jh4_ip }}:{{ jh4_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'ssh -i $JH2_SSH_PRIVATE_KEY -W {{ jh3_ip }}:{{ jh3_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'ssh -i $JH1_SSH_PRIVATE_KEY -W {{ jh2_ip }}:{{ jh2_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null {{ jh1_ssh_user }}@{{ jh1_ip }}'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"' {{ jh2_ssh_user }}@{{ jh2_ip }}'"'"'"'"'"'"'"'"' {{ jh3_ssh_user }}@{{ jh3_ip }}'"'"' {{ jh4_ssh_user }}@{{ jh4_ip }}'');
my $five_hop=q(ansible_psrp_protocol: 'http',ansible_psrp_proxy: 'socks5h://unixsocket/tmp/mysocks-{{ account_code }}-{{ trans_num }}-{{ jh_socks_port }}',ansible_ssh_common_args: '-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='ssh -i $JH5_SSH_PRIVATE_KEY -W %h:%p -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'ssh -i $JH4_SSH_PRIVATE_KEY -W {{ jh5_ip }}:{{ jh5_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'ssh -i $JH3_SSH_PRIVATE_KEY -W {{ jh4_ip }}:{{ jh4_ssh_port }} -oPubkeyAuthentication=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'ssh -i $JH2_SSH_PRIVATE_KEY -W {{ jh3_ip }}:{{ jh3_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oProxyCommand='"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'ssh -i $JH1_SSH_PRIVATE_KEY -W {{ jh2_ip }}:{{ jh2_ssh_port }} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null {{ jh1_ssh_user }}@{{ jh1_ip }}'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"' {{ jh2_ssh_user }}@{{ jh2_ip }}'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"'"' {{ jh3_ssh_user }}@{{ jh3_ip }}'"'"'"'"'"'"'"'"' {{ jh4_ssh_user }}@{{ jh4_ip }}'"'"' {{ jh5_ssh_user }}@{{ jh5_ip }}'');

$win_con="ansible_connection: \'psrp\'";
$linux_con="ansible_connection: \'ssh\'";
###########################
#other vars. Do not touch!
my $create_time = strftime "%Y-%d-%b %H:%M:%S", localtime;
#our $build_version="20.5"; #release number
our $build_version="$create_time"; #release number
our $admin='aroland@br.ibm.com';
our $grepcmd='grep'; #default grep command
our %hoststable; #loads xlsx file into memory
our %idcontroltable; #loads groups into memory + current existing groups on Tower + hosts -> and all its already checked ids to avoid extra queries
#our @group_types = qw( credential proxy usertype);
our $abort_flag=0;
#our %groupids_hash; #will hold loaded groupids
#our @hostloadedlist : shared; #contains $hoststable{os}{hosts} array for threads
our $print_mutex : shared;
our $thread_counter : shared;
our $thread_total : shared;
our $progress : shared;
our $default_data = $hosts_fqdn_header; #this is going to be the main reference in the inventory either hostname (default) or IP
our $organization; #placeholder for organization

#host table definition explanation ---------------------------------
#$header +>{ 						-> defined by user on the beginning of the code
#mandatory  => 0,					-> 0/1 if mandatory
#default => "N",					-> default may be ANY value
#column_number  => 'NA',			-> NA until found in the spreadsheet (remains if not found)
#create_var_host => 'N',			-> N = no creation, VAR_LIST= receives a comma separated list from xlsx and validate. ANY other name-> used as varname. Like ANY=CONTENTOFXLSCELL
#create_var_group => 'N',			-> USED ONLY IF create_group=Y. N = no creation, Anything else is a list of comma separated vars like: var1: \'d=c:%p\',var2: \'allinsidequote\'
#create_group => 'Y',				-> N = no creation, Y = create group based on standard or GROUP_LIST = command separated group list come from XLS
#group_type => 'blacklist_event'	-> empty if CREATE_group = N. Otherwise ANYTHING as in the standard: blacklist_*, access_*, ud, CAREFULL! these group types ARE used inside the code
#create_smartinventory => ''		-> Only meaningful if create_group=Y 0/1 auto create smart inventory using that group as filter --> TODO not implemented
#},
our %spreadsheet_host_columns= (
	$hosts_organization_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_action_header => {
		mandatory  => 0,
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	#$hosts_hostname_header => {
		#mandatory  => 1,
		#column_number  => 'NA',
		#create_var_host => 'N',
		#create_var_group => 'N',
		#create_group => 'N',
		#group_type => ''
	#},
	$hosts_connectionaddress_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'ansible_host',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_ip_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'ipaddress',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_fqdn_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'fqdn',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_ostype_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'ostype',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'ud'
	},
	$hosts_devicetype_header => {
		mandatory  => 1,
		default => "compute",
		column_number  => 'NA',
		create_var_host => 'devicetype',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_tier_header => {
		mandatory  => 1,
		column_number  => 'NA',
		create_var_host => 'tier',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'ud'
	},
	$hosts_blacklisted_event_header => {
		mandatory  => 0,
		default => "N",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'blacklist_event_server:\'yes\'',
		create_group => 'Y',
		group_type => 'blacklist_event'
	},
	$hosts_blacklisted_bigfix_header => {
		mandatory  => 0,
		default => "N",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'blacklist_hc_server:\'yes\'',
		create_group => 'Y',
		group_type => 'blacklist_hc'
	},
	$hosts_blacklisted_patchscan_header => {
		mandatory  => 0,
		default => "N",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'blacklist_patchscan_server:\'yes\'',
		create_group => 'Y',
		group_type => 'blacklist_patchscan'
	},
	$hosts_access_event_header => {
		mandatory  => 0,
		default => "Y",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'access_event'
	},
	$hosts_access_bigfix_header => {
		mandatory  => 0,
		default => "Y",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'access_hc'
	},
	$hosts_access_patchscan_header => {
		mandatory  => 0,
		default => "Y",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'access_patchscan'
	},
	$hosts_proxygroup_header => {
		mandatory  => 1,
		default => "N",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'sshproxy'
	},
	$hosts_credgroup_header => {
		mandatory  => 1,
		default => "N",
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'Y',
		group_type => 'cred'
	},
	$hosts_hostvar_header => {
		mandatory  => 0,
		column_number  => 'NA',
		create_var_host => 'VAR_LIST',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_middlewarevar_header => {
		mandatory  => 0,
		column_number  => 'NA',
		create_var_host => 'VAR_LIST',
		create_var_group => 'N',
		create_group => 'N',
		group_type => ''
	},
	$hosts_groupmemberlist_header => {
		mandatory  => 0,
		column_number  => 'NA',
		create_var_host => 'N',
		create_var_group => 'N',
		create_group => 'GROUP_LIST',
		group_type => ''
	}
);

#group table definition
our %spreadsheet_group_columns= (
	$groups_name_header => {
		mandatory  => 1,
		column_number  => 'NA'
	},
	$groups_category_header => {
		mandatory  => 1,
		column_number  => 'NA'
	},
	$groups_mandatoryvars_header => {
		mandatory  => 0,
		column_number  => 'NA'
	},
	$groups_extravars_header => {
		mandatory  => 0,
		column_number  => 'NA'
	},
        $groups_mandatory_user_inputs_header => {
               mandatory   => 0,
               column_number => 'NA'
        }

);

#define values that can be used on Group category on xls/csv and how they are translated to group name used in inventory
our %grouptype_category_values=(
"user defined" => "ud",
"credential groups" => "cred",
"blacklisting groups" => "blacklist",
"proxy groups"  => "sshproxy",
"access groups" => "access"
);

#help
sub usage {
my ($additional_msg)= @_;
print "$additional_msg\n" if (defined($additional_msg));

print <<EOHIPPUS;

Description
Import xlsx to Ansible Tower - it must have 2 tabs: hosts and groups (with proper columns) see note #1 for expected columns:

USAGE:
./at-inventory-import.pl

[-f|--file] <filename> specify xlsx filename default: $reportdb_file
[-i|--inventoryname] <tower inventory to upload> Tower inventory name to import ( Optional). If proivded will be used else organization code will be used.
[-j|--json] print in json format
[-y|--yaml] print in yaml format --- draft, under development
[-o|--organization] 3 letter code
[-m|--maxthreads] Maximum number of parallel threads to use on import. Default: $maxthreads
[-d|--debug] print debug messages
[-v|--verbose] print details and extra info
[-w|--overwrite] overwrite host or group if already exists. ***use it with caution as it overwrites existing host and group variables.***
[-g|--groups-file] Groups file containing groups details. Note: This option if used need to provide option -k as well and cannot use option -f when -k and -g are used.
[-k|--hosts-file] Host file for containing hosts details. Note: This option if used need to provide option -g as well and cannot use option -f when -k and -g are used.
[-b|--tiergroup]  if this option is provided to the script tier group will not be created. By default tier group is created and hosts are associated to the respective groups.
[-c|--ostypegroup] if this option is provided to the script ostype  group will not be created. By default ostype group is created and hosts are associated to the respective groups.
[-a|--credcheck] if this option is provided to the script then there will be no check if credentials exists in tower or not.

[-h|--help]

Examples
For examples checkout the instructions tab in the CACF_Inventory_Upload_Template-*.xlsx file at git repo https://github.ibm.com/cacf/inventory_load


EOHIPPUS

print "\nNote #1:Current config expected column headers, case insensitive:\n";
usage_xlsx_format();
#usage_tower_cli_help();

exit 1;
}

sub usage_tower_cli_help{

print <<EOHIPPUS;

#Tower-cli initial setup ================================
For latest instructions go to: https://github.ibm.com/cacf/inventory_load/
EOHIPPUS

}

sub remove_entities {
  my ($text) = @_;
  if ($text){ 
    $text =~ s/&quot;/"/g;
    $text =~ s/&amp;/&/g;
    $text =~ s/&apos;/'/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&#10;/\n/g;
    $text =~ s/‘/'/g;
    $text =~ s/’/'/g;
  }
    return $text;
}
#check if files exist, there may be more consistency checks in the future
sub tower_cli_check{
$os=sup_check_os();
$grepcmd="findstr" if ($os =~ /windows/i);
	#check if tower-cli exists if not using json
#if (!$json_flag){
if (!($json_flag || $ini_flag || $yaml_flag || $playbook_flag)){

        #test if tower-cli is installed
        $version=`tower-cli --version 2>&1`;
        $ret=$?;
        chomp($version) if ($ret==0);

        #print Dumper $version;exit;
        #if (!-e '/usr/local/bin/tower-cli') {
        #if ($version !~ /^\s*Tower\sCLI\s(?:\d|\.)+\s*$/i){
        if ($ret != 0){
                print STDERR "-->tower-cli not found (or not in PATH). Please check help for installation/config instructions\n";
                print $version if ($verbose);
                usage_tower_cli_help();
                exit 1;
        }

        #test if access is authorized
        $auth=`tower-cli organization list 2>&1`;
        $ret=$?;
        chomp($auth) if ($ret==0);

        #print Dumper $version;exit;
        #if (!-e '/usr/local/bin/tower-cli') {
        #if ($version !~ /^\s*Tower\sCLI\s(?:\d|\.)+\s*$/i){
        if ($ret != 0){
                print STDERR "-->tower-cli not authorized to access tower, check client configuration\n";
                print $auth if ($verbose);
                usage_tower_cli_help();
                exit 1;
        }
}


}
sub test_components{
my ($reportdb_file)=@_;
$os=sup_check_os();
$grepcmd="findstr" if ($os =~ /windows/i);

#test if saved by MS excel, encoding, Libbreoffice need decoding... others not tested
#Know types: LibreOffice5.3.6.1, Microsoft Excel
if (!$csv_flag){

#import xlsx file must exist
if (! -e $reportdb_file){
	print STDERR "Exiting...Missing default import file: $reportdb_file\nYou may specify a different current report with -f <filename>\n";
	exit 1;
}

#this part just unzips xlsx to check its encoding, there are differences/incompatibilities
$docspropfile='';
 use IO::Uncompress::Unzip qw($UnzipError);
    my $zipfile = $reportdb_file;
    my $u = new IO::Uncompress::Unzip $zipfile
        or die "Cannot open $zipfile: $UnzipError";
    my $status;
    for ($status = 1; $status > 0; $status = $u->nextStream())
    {
         my $name = $u->getHeaderInfo()->{Name};
        next if ($name ne "docProps/app.xml");
        #warn "Processing member $name\n" ;
        my $buff;
        while (($status = $u->read($buff)) > 0) {
            #print "TEST:$buff\n";
            $docspropfile.=$buff; #just save the contents which is usually small
            #print Dumper $buff;
        }
        last if $status < 0;
    }
    die "Error processing $zipfile: $!\n"
        if $status < 0 ;


$is_ms_excel=0; #default
$is_ms_excel=1 if ($docspropfile =~ /<Application>Microsoft Excel/);
#$is_ms_excel=`unzip -p $reportdb_file docProps/app.xml|grep -i '<Application>Microsoft Excel'|wc -l`;
#$savedfiletype=`unzip -p $reportdb_file docProps/app.xml|awk -F'Application>' '{print \$2}'|tr -d '</\n'`;
if ($docspropfile =~ /^.*<Application>(.*)<\/Application>.*$/m){
	$savedfiletype = $1;
}else{
	print STDERR "Check docProps/app.xml variant:$docspropfile\n";
	exit 1;
}
if($is_ms_excel == 0){
	print "-Warning: file $reportdb_file was not saved with Microsoft Excel,but $savedfiletype. Encoding may fail, only MS Excel is 100% compatible...\n" if($verbose);
	#exit;
}

#print Dumper $is_ms_excel;
#print Dumper $savedfiletype;
#exit;
}

#test csv files exist
if ($csv_flag){
	$groupsfile=$organization.'_'.$csv_groups_suffix;
	$hostsfile=$organization.'_'.$csv_hosts_suffix;
	if (! -e $groupsfile || ! -e $hostsfile){
		print STDERR "Exiting...Missing default import file: $hostsfile or $groupsfile\n";
		exit 1;
	}
}

}


#https://docs.ansible.com/ansible/latest/dev_guide/developing_inventory.html#tuning-the-external-inventory-script
#_meta hostvars is needed to avoid re reading inventory
#this sub can also be used to include host specific variables when receiving that information from XLSX
sub add_meta_hostvar
 {
my ($host_to_add,$hostvariable_string)= @_;
my %hostvariable; #empty hash

print "-add_meta_hostvar->$host_to_add->$hostvariable_string\n" if ($debug>=2);
#just a test for a host variable, this will probably comming from a column in the XLSX file
#$hostvariable_string=' ansible_host:10.16.10.11 ansible_ssh_common_args: \'-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="connect-proxy -S 127.0.0.1:{{ jh_socks_port }} %h %p"\'' if ($host_to_add eq '10.1.3.7');
#end of test, this must come from xlsx

$reference=convert_stringtohash($hostvariable_string);
if ($reference ne ''){
	%hostvariable = %{$reference};
}
#print Dumper \%hostvariable;

	$hoststable{_meta}{hostvars}{$host_to_add}=\%hostvariable;
}

#add group variables
#receive the groupname and the hash reference with variable
#also add/increment "all" group which is a default for tower inventory
sub add_groupvar {
my ($group_to_add,$groupvariable)= @_;
#my %groupvariable = %{$groupvariable_hashref}; #hash de-reference
my %groupvariable_hash; #empty hash

print "-add_groupvar:$group_to_add,$groupvariable\n" if ($debug>=2);

#convert new string to hash
$reference=convert_stringtohash($groupvariable);
if ($reference ne ''){
	#merge current variables with new
	%groupvariable_hash = %{$reference};
}

#Check whether current content exists, being carefull to not create the key on check - autovivification
if (keys (%hoststable) && exists($hoststable{$group_to_add}) && exists($hoststable{$group_to_add}{vars})){
		$gotvar_ref=$hoststable{$group_to_add}{vars}; #get the reference to the hash
		%var_list = %{$gotvar_ref}; #rebuild the hash
		%groupvariable_hash = (%var_list,%groupvariable_hash); #merge the hashes
}

#add the group to "all"
add_group_toall($group_to_add);

$hoststable{$group_to_add}{vars}=\%groupvariable_hash;
}

#"all" is a tower definition with an array of all groups... and including "ungrouped" it might contain vars but we are not handling this
sub add_group_toall{
my ($group_to_add)= @_;
	#add the group to "all"
	if (defined($hoststable{all}{children})){
		@groupsarray=@{$hoststable{all}{children}};
		#push to array if not already present
		 $present_already = grep (/^$group_to_add$/,@groupsarray);
		if (!$present_already){#if new group... dont duplicate entries
			push(@groupsarray,$group_to_add);
			@sorted_ga=sort { $a cmp $b } @groupsarray;
			$hoststable{all}{children}=[@sorted_ga];
		}
	}else{ #new array
		undef @groupsarray; #clear it otherwise there will be garbage
		push(@groupsarray,"ungrouped"); #this is a default name used by tower
		push(@groupsarray,$group_to_add);
		@sorted_ga=sort { $a cmp $b } @groupsarray;
		$hoststable{all}{children}=[@sorted_ga];
	}
}

#get group pattern type and return it
sub validate_group_pattern_type{
my ($groupname)= @_;
if ($groupname !~ /^\w{3}_grp_(sshproxy|cred|blacklist|ud|access)_.*$/){
		print "...Group received $groupname but expects this regex:".'^\w{3}_grp_(sshproxy|cred|blacklist|ud|access)_\w+$',"\n" if ($debug);
		return '';
	}
return $1;
}

#validate format standards
#in: data and type (based on column definition: ip, groupname, etc)
#out: valid/invalid 1/0
sub validate_standard{
my ($datatocheck,$pattern_type)= @_;

#here we must define all cacf standards to be validaded
print "Validating: $datatocheck,$pattern_type\n" if ($debug>=3);

#if bypass is set always return true = do not make any validation
if($bypass_namestandard_validation){
	return 1;
}

#device types
if ($pattern_type eq $hosts_devicetype_header){
	$regex="Appliance|Application Switch|Chassis|Compute|Cloud|Concentrator|Container|Firewall|Gateway|Hypervisor|Module|Network|PC|Power|Router|SAN Switch|SAN/NAS|Server|Storage|StorageElement|Switch|VoiceGateway|VoiceMail|Wireless|_Other_";
	if ($datatocheck !~ /^($regex)$/i){
		print "$hosts_devicetype_header received $datatocheck is invalid, expecting: $regex\n" if ($verbose);
		return 0;
	}
}

#tier type
if ($pattern_type eq $hosts_tier_header){
	#$regex="Beta|Blacklist|DEVELOPMENT|DR|Dev|Integration|OTHER|PRE_DEVELOPMENT|PRE_PRODUCTION|PRE_TEST|PRODUCTION|QA|RECOVERY|Staging|TBD|TEST|UNKNOWN|NonProduction|preprod";
	if ($datatocheck !~ /^($group_check_regex)$/i){
		print "$hosts_tier_header received $datatocheck is invalid, expecting: $regex\n" if ($verbose);
		return 0;
	}
}

#IP column
if ($pattern_type eq $hosts_ip_header){
	$result=sup_valid_ip($datatocheck);
	return $result;
}

#membership list validation
if ($pattern_type eq $hosts_groupmemberlist_header){
	#if ($datatocheck !~ /^\s*(?:\w|-)*(?:\s*,\s*(?:\w|-)+\s*)*\s*$/i){
	if ($datatocheck !~ /^\s*(?:[A-Za-z0-9._])*(?:\s*,\s*(?:[A-Za-z0-9._])+\s*)*\s*$/i){
		print "...Group received $datatocheck but expects a comma separated list of groups with [A-Za-z0-9._]\n" if ($verbose);
		return 0;
	}
}

#organization names
if ($pattern_type eq "organization_name"){
	if ($datatocheck !~ /^\w{3}$/i){
		print "...Organization received \"$datatocheck\", but expects this regex: ".'^\w{3}$',"\n" if ($verbose);
		return 0;
	}
}

#Blacklist/Access Y/N columns
if ($pattern_type =~ /$hosts_blacklisted_event_header|$hosts_blacklisted_bigfix_header|$hosts_blacklisted_patchscan_header|$hosts_access_event_header|$hosts_access_bigfix_header|$hosts_access_patchscan_header/){
	if ($datatocheck !~ /^\s*(?:Y|N|\s*)\s*$/i){
		print "...Column \"$pattern_type\" got $datatocheck, but expects this regex:".'^(Y|N)$',"\n" if ($verbose);
		return 0;
	}
}

#proxycredvarpattern
#old: xxx_sshproxy_<custom>  xxx_os_credential_<custom>
#sshproxy_credential: anything, os_credential: anything
if ($pattern_type eq "proxycredvarpattern"){
	#proxycredvarpattern must come with data in the format $typefound#$variable
	($typefound,$variable)=split (/#/,sprintf '%s',$datatocheck);
	$controlthisrun=0; #flag if abortion happened on this run
	#print "EXTRA---------$typefound,$variable\n";

	if ($typefound eq "cred"){
		@required_vars = qw( os_credential ansible_connection );
		foreach $reqvar (@required_vars){
			#if ($variable !~ /^\s*$organization(?:_\w+_credential)_\w+\s*:\s*((?:(?:'[^']*')))$/){
			#if ($variable !~ /^\s*os_credential\s*:\s*(?:'[^']*')\s*$/i){
			if ($variable !~ /$reqvar/){
				#print "Credentials variable name received $variable but expects this: ".'xxx_os_credential_<custom>:\'value\'',"\n" if ($debug);
				print "...Credentials variable name \"$reqvar\" missing on cell:\"$variable\" Summary below\n" if ($verbose);
				$abort_flag=1;
				$controlthisrun=1;
			}
		}
		return 0 if ($abort_flag && $controlthisrun);
	}elsif($typefound eq "sshproxy"){
		@required_vars = qw( jumphost_credential ansible_psrp_proxy ansible_psrp_protocol ansible_ssh_common_args );
		#@required_vars = qw( jumphost_credential ansible_psrp_proxy ansible_psrp_auth ansible_psrp_protocol ansible_psrp_message_encryption ansible_ssh_common_args);
		foreach $reqvar (@required_vars){
			#if ($variable !~ /^\s*$organization(?:_sshproxy)_\w+\s*:\s*((?:(?:'[^']*')))$/){
			#if ($variable !~ /^\s*jumphost_credential\s*:\s*(?:'[^']*')\s*$/i){
			if ($variable !~ /$reqvar/){
				print "...Proxy variable name \"$reqvar\" missing on cell:\"$variable\" Summary below\n" if ($verbose);
				$abort_flag=1;
				$controlthisrun=1;
			}
		}
		return 0 if ($abort_flag && $controlthisrun);
	}

}

return 1; #if there is no standard or compliant, approve it
}

#return hash reference to a converted host/group variable string
#we might need to add more arguments in the dictionary to accept different vars, examples
#ansible_host:10.16.10.11 which include the ip
sub convert_stringtohash{
my ($stringwithvariable)= @_;
$stringwithvariable='' if(!defined($stringwithvariable));
#ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="connect-proxy -S 127.0.0.1:{{ jh_socks_port }} %h %p"'
#verify if variable has the correct definition

print "-convert_stringtohash->$stringwithvariable\n" if ($debug>=2);

undef %var_hash; #create an empty hash
$interactions=0;
#^\s*(\w+)\s*:\s*('[^']*')$
#^(\s*\w+\s*:\s*(?:(?:'[^']*')))\s*,*\s*(.*)$/
#while ($stringwithvariable =~ /^(\s*\w+\s*:\s*(?:'[^']*')\s*)(?:\s*,(.*))*$/){ #var1: 'd=c:%p',var2: 'allinsidequote' ,var3 : '101.202anythingbutspace'
while ($stringwithvariable =~ /^(\s*\w+\s*:\s*(?:'[^,]*')\s*)(?:\s*,(.*))*$/){ #var1: 'd=c:%p',var2: 'allinsidequote' ,var3 : '101.202anythingbutspace'

		$toanalyse=$1;
		$newstringwithvariable=$2;
		$newstringwithvariable='' if (!defined($newstringwithvariable));
		print "Analysing: $toanalyse from $stringwithvariable\n" if ($debug >= 3);
		#if($toanalyse =~ /^\s*(\w+)\s*:\s*('[^']*')\s*$/){
		if($toanalyse =~ /^\s*(\w+)\s*:\s*('[^,]*')\s*$/){
			$variable_used= $1;
			$clean_escaped_quotes= $2;
                        $clean_escaped_quotes =~ /'(.*)'/;
                        $clean_escaped_quotes= $1;
			#$clean_escaped_quotes =~ s/\'//g;
			print "Found pair $variable_used => $clean_escaped_quotes\n" if ($debug >=3);
			#%var_hash=($variable_used => $clean_escaped_quotes);
			$var_hash{$variable_used}= $clean_escaped_quotes;
			#print Dumper \%var_hash;exit;
		}else{
			print "-Group/Host variable must be in the format (disregard spaces) variable: 'content',variable2: 'content', etc. PROBLEM--> $toanalyse\n\n";
			$abort_flag=1; next;
			#exit;
		}
		#print "New string to convert:$newstringwithvariable:\n" if ($debug);
		$stringwithvariable=$newstringwithvariable;
		$interactions++;
	}
	print "**Exited loop with :$stringwithvariable: pending\n" if ($debug  >= 2 && $stringwithvariable ne '');
	if($stringwithvariable eq '' && $interactions == 0){ #it came here empty, nothing to load so return empty
		#print "convert is empty\n";
		return '';
	}elsif($stringwithvariable ne ''){ #meaning $stringwithvariable has something but does not match pattern
		print "-Group/Host variable must be in the format (disregard spaces) variable: 'content',variable2: 'content',etc. PROBLEM--> $stringwithvariable\n\n";
		$abort_flag=1; #next;
	}
	#if we got here while consumed all variables , we can return hash
	return \%var_hash;
}

#merge all ostype into linux/windows or any other defined groups
#these will be used to "tag"host in those groups
sub check_ostype_merge {
my ($ostype_in,$row_number)= @_;

	if ($ostype_in =~ /redhat|centos|linux|unix|ubuntu|aix|solaris|suse/i){
		$ostype_out="linux";

	}elsif($ostype_in =~ /win|windows/i){
		$ostype_out="windows";
	}
	#elsif ($ostype_in =~ /createanewtype/i){
		#$ostype_out="yournewtype";
	#}
	elsif ($ostype_in =~ /Arista|EOS|Cisco|IOS|NX-OS|Juniper|Junos OS|VyOS/i){
		$ostype_out="network";
	}
	else {
		print "Could not identify OSTYPE: $ostype_in in row: ".($row_number+1)."\nPlease check export or add new types on check_ostype_merge sub. Process will abort\n";
		$abort_flag=1;
		$ostype_out="other"; }

print "-check_ostype_merge:$ostype_in,$row_number:Detected:$ostype_out\n" if ($debug>=2);
	return $ostype_out;
}

#get inventory id , this is needed to assign hosts to groups since group name might be present in more than on inventory and cant reference them by name
#in: inventory name
#out inventory_id, save organization name
sub get_inventory_id{
my($inventory_name)=@_;
$inv_ids=`tower-cli inventory list --name "$inventory_name" 2>&1 |$grepcmd "$inventory_name"`;
@inlist=split /\n/, sprintf '%s', $inv_ids;

foreach $inventory (@inlist){
	if($inventory =~ /^\s*(\d+)\s+$inventory_name\s+(\d+)\s*$/){
		$invid=$1;
		$orgid=$2;
		#now get organization name too
		$orgquery=`tower-cli organization list --query id $orgid 2>&1 | $grepcmd "$orgid"`;
		if($orgquery =~ /^\s*\d+\s+(.*)$/){
			$organization=sup_trim($1);
			validate_standard($organization,"organization_name");
			return $invid; #just return if organization is also valid
		}
	}
}
print STDERR "Could not find Inventory id for $inventory_name in tower\n";
print STDERR "$inv_ids\n";
exit 1;
}

#this is needed to assign hosts to groups since group name might be present in more than on inventory and cant reference them by name
#IN: inventory_id and groupname; if groupname is empty fill in hash
#OUT: groupid
sub get_group_id{
my($inventory_id,$groupname)=@_;

return $idcontroltable{group}{$groupname}{id} if ($groupname ne '' && defined($idcontroltable{group}{$groupname}{id}));
$cmd="tower-cli group list -a -i $inventory_id --name \"$groupname\" 2>&1";
$cmd="tower-cli group list -a -i $inventory_id 2>&1" if ($groupname eq '');
$group_ids=`$cmd`;
@gplist=split /\n/, sprintf '%s', $group_ids;
foreach $group (@gplist){
	#if($group =~ /^\s*(\d+)\s+$groupname\s+$inventory_id$/){
	if($group =~ /^\s*(\d+)\s+(.*\w)\s+$inventory_id$/){
		$groupid=$1;
		$groupfound=$2;
		$idcontroltable{group}{$groupfound}{id}=$groupid;
		$idcontroltable{group}{$groupfound}{type}="already_present";
		#$groupids_hash{$groupfound}=$groupid;
	}
}
if ($groupname ne '' && defined($idcontroltable{group}{$groupname}{id})){
	return $idcontroltable{group}{$groupname}{id};
}elsif($groupname ne ''){
	print STDERR "Could not find group id for $groupname ,inventory id $inventory_id on this list:\n";
	print STDERR "$group_ids\n";
	exit 1;
}
return; #if calling for full group returns nothing
}

#this is needed to assign hosts to groups since group name might be present in more than on inventory and cant reference them by name
#IN: inventory_id and groupname
#OUT: groupid
sub get_host_id{
my($inventory_id,$hostname)=@_;

#get_host_id(3,"api-ap-dbprod-1b.apieco.softlayer.com");
$host_ids=`tower-cli host list -i $inventory_id --name $hostname  2>&1|$grepcmd $hostname`;
@htlist=split /\n/, sprintf '%s', $host_ids;
foreach $host (@htlist){
	if($host =~ /^\s*(\d+)\s+$hostname\s+$inventory_id\s+\w+$/){
		$hostid=$1;
		#$groupids_hash{$groupname}=$groupid;
		return $hostid;
	}
}
print STDERR "Could not find host id for $hostname ,inventory id $inventory_id on tower\n";
print STDERR "You may try to run the code with -v and -d for more information. An Error: You don't have permission to do that (HTTP 403) might indicate you ran out of licenses\n";
print STDERR "If a few hosts imported before this abort and you got the above error, please check if there are Tower Licenses Available!\n";
print STDERR "Go To Tower and imediatelly try to create a new host after the problem. Licensing is per host.\n";
#print STDERR "$host_ids\n";
exit 1;
}

#print some status, %, etc
sub thread_print_progress{
my($text,$current,$total)=@_;
lock($print_mutex);
$total=$thread_total if (!defined($total) || $total eq '');
#$current=$thread_total-$thread_counter;
$percent_complete=sprintf("%.2f", $current/$total*100);
print "$text Progress: $current of $total : $percent_complete% Done.\n";

}

#create thread using thread_func sub with parameters.
sub thread_call{
my ($inventory_id)=@_;
#my ($ostype,$group_id,$inventory_name)=@_;

$thread_total=$thread_counter;# + 1;
undef @threads;
#print "thread_counter :$thread_counter \n";
if ($thread_counter >0){

for (1 .. $maxthreads){
	my $thr = threads->create('thread_func',$inventory_id);
	push @threads, $thr;
}
#wait for threads to finish
foreach (@threads){
	$_->join;
	#print "thread ? $_\n";
}
#select STDOUT;$| = 1;
print "- All threads have finished\n" if ($verbose);

}
}

#this is actually the first code that the thread sees. When out of this sub it actually ends the thread and return control to parent
#from this point on, all care must be taken to avoid deadlocks on shared variables
sub thread_func {
#my ($ostype,$group_id,$inventory_name)= @_;
my ($inventory_id)= @_;

my $id  = threads->tid();
while ((my $i = thread_get_number()) >= 1){
		$loaddata = $idcontroltable{host}{$i};
                $is_host_in_tower = grep (/^$loaddata$/,@tower_hostnames);
                if($is_host_in_tower){
                  if($overwrite){
		    thread_print("-Thread $id inserting host: $loaddata, inv_id:$inventory_id") if ($verbose);
		    thread_insert_host($loaddata,$inventory_id);
		    thread_print_progress("Adding Hosts",thread_set_progress(),'');
                  }else{
                    print "Host already exists in tower. So skipping the creation of host $loaddata\n" if($verbose);
                    push @hosts_skipped, "Host already exists in tower. So skipping the creation of host $loaddata\n";
                  }
                }else{
		  thread_print("-Thread $id inserting host: $loaddata, inv_id:$inventory_id") if ($verbose);
		  thread_insert_host($loaddata,$inventory_id);
		  thread_print_progress("Adding Hosts",thread_set_progress(),'');
                }

  }
return 1;
}

#prints output to log file locking for exclusive access
sub thread_print{
	my ($msg)= @_;
	lock($print_mutex);
	print $msg."\n";
	return 1;
}

#get an array element to work on (get just a number)
sub thread_get_number{
	lock($thread_counter);
	#print "test: $thread_counter\n";
	return $thread_counter--;
}

#a counter to use as the progress
sub thread_set_progress{
	lock($progress);
	return $progress++;
}

#threaded sub to create hosts
sub thread_insert_host {
my ($data,$inventory_id)= @_;
#my ($data,$group_id,$inventory_name)= @_;

		$json_hvars = '';
		#need to check _meta for host specific variables
		$gotvar_ref=$hoststable{_meta}{hostvars}{$data}; #get the reference to the hash
		%var_list = %{$gotvar_ref}; #rebuilt the hash
		$json_hvars = encode_json \%var_list;
    if($overwrite){
		  $towerhost='tower-cli host create --force-on-exists --name "'.$data.'" --inventory "'.$inventory_id.'" --description "uploaded at-inventory-import '.$build_version.'"';
    }else{
		  $towerhost='tower-cli host create --name "'.$data.'" --inventory "'.$inventory_id.'" --description "uploaded at-inventory-import '.$build_version.'"';
    }
		#if there are variables set, append
		if ($json_hvars ne ''){
			$os=sup_check_os();
			if ($os =~ /linux|darwin/i){
				$towerhost.=' --variables \''.$json_hvars.'\' 2>&1';
			}elsif ($os =~ /windows/i){
				$converted_hvars=convert_windows_var($json_hvars);
				$towerhost.=' --variables "'.$converted_hvars.'" 2>&1';
			}

		}else{
			$towerhost.=' 2>&1';
		}
		thread_print "$towerhost" if ($debug);

		$cmd=$towerhost;
		$ret=`$cmd`;
                if($ret =~ /^Error:.*/){
                   print "Error in creating host $data. $ret\n";
                   push @host_create_errors, "Error in creating host $data. $ret\n";
                }

		thread_print "$ret" if ($debug); #more info when host creation fails

		#get hostid
		$host_id=get_host_id($inventory_id,$data); #get host id
		$group_scalar= $idcontroltable{host}{$data}{groups};
		#@group_array=split/,/, sprintf '%s', $group_scalar;

		#assign hosts to groups
		foreach $groupname (split/,/, sprintf '%s', $group_scalar){
			#get group id
			$group_id=$idcontroltable{group}{$groupname}{id};
			thread_print "-Associating $data -> $groupname" if ($verbose);
			$towerassign='tower-cli host associate --host "'.$host_id.'" --group "'.$group_id.'" 2>&1';
			$cmd=$towerassign;
			$ret=`$cmd`;
			thread_print "$towerassign" if ($debug);
		}

}

#print command or prepare them to execution

sub call_inventory_vars_create {
  #$out=`tower-cli  inventory list --name ${organization}_inventory -f json|grep variables`;
  @out= grep(/variables/,`tower-cli  inventory list --name ${organization}_inventory -f json 2>&1`);
  $out=join '',@out;
  print "Existing inventory vars: $out\n";
  $next_cred_exists=1; #Assuming vars not present
  $blueid_exists=1; #Assuming vars not present
  if ($out =~ /(.*?)next_credential(.*?):/i){
    print "Mandatory variable next_credential for inventory exists already\n";
    $next_cred_exists=0;
  }else{
    print "Mandatory variable next_credential for inventory not present\n";
  }

  if ($out =~ /(.*?)blueid_shortcode(.*?):(.*?)$organization.*/i){
    print "Mandatory variable blueid_shortcode for inventory exists already\n";
    $blueid_exists=0;
  }else{
    print "Mandatory variable blueid_shortcode for inventory not present\n";
  }

 # if ($next_cred_exists == 1 || $blueid_exists == 1)
 # {
 #   print "Mandatory variables next_credential or blueid_shortcode do not exist\n";
 #   print "Creating variables next_credential and blueid_shortcode\n";
 #   $cmd=`tower-cli inventory modify --name ${organization}_inventory --variables '{"next_credential":"next_credential","blueid_shortcode":"$organization"}'`;
 #   if($cmd =~ /Resource changed/){
 #     print "Inventory variables modified successfully\n" 
 #   }elsif($cmd =~ /Error/){
 #    print "There was an error while updating inventory variables\n";
 #    print "$cmd\n";
 #   }else{
 #     print "There is no change to inventory vars\n";
 #   }
 #}
}

sub call_towercli {

#load current groups from inventory, also capturing ids. Update idcontroltable
print "--Loading current Tower groups...\n" if ($verbose);
if(!$overwrite){
get_group_id($inventory_id,''); #load current ones from inventory, so avoid sending creation again
}
print "-IDcontrolTable:\n" if($debug >= 2);
print Dumper \%idcontroltable if($debug >= 2);

#just count how many groups to add
$gtotal=0;
foreach $keys (keys %{ $idcontroltable{group} }){
	#$gtotal++ if($idcontroltable{group}{$keys}{id} || $idcontroltable{group}{$keys}{id} eq 'NA');
	$gtotal++ if( $idcontroltable{group}{$keys}{id} eq 'NA');
}
$gprogress=0;
#print Dumper \%idcontroltable;

#pbased on id control create groups (without id) and load their new ids
foreach $group (keys %{ $idcontroltable{group} }){
  if($idcontroltable{group}{$group}{id} eq 'NA'){
		thread_print_progress("-Adding Group \"$group\"",$gprogress++,$gtotal);
		$json_gvars='';
		if (defined ($hoststable{$group}{vars})){
			#print "$group:$hoststable{$group}{vars}\n"; #print header
			$gotvar_ref=$hoststable{$group}{vars}; #get the reference to the hash
			%var_list = %{$gotvar_ref}; #rebuilt the hash
			$json_gvars = encode_json \%var_list;
		}
	if($overwrite){
		  $towergroup='tower-cli group create  --force-on-exists --name "'.$group.'" --inventory "'.$inventory_id.'"';
        }else{
		  $towergroup='tower-cli group create --name "'.$group.'" --inventory "'.$inventory_id.'"';
        }

		#if there are variables set, append
		if ($json_gvars ne ''){
                  #write vars to file
                  my $varsfile="vars.json";
                  open my $vars_file, ">", $varsfile;
                  print $vars_file  $json_gvars;
                  close $vars_file;
		  $towergroup.=' --variables @vars.json 2>&1';

	        }else{
		  $towergroup.=' 2>&1';
		}

		print $towergroup."\n" if ($debug);
		$cmd=$towergroup;
		$ret=`$cmd`;
                unlink "vars.json";
                if($ret =~ /Error:/){
                 print "Error in creating the group $group\n";
                 print "$ret\n";
                }

		#if requested to create all smart inventories - one for each group created
		if ($smartinventory_flag){
			#smart inventory name creation
			$grouptype=$idcontroltable{group}{$group}{type};
			$group =~ /^($organization)_grp_($grouptype)_(\w+)$/; #just gather parts to be used next
			$smart_name=$organization."_smartinv_".$grouptype."_$3";
			$smartinventory='tower-cli inventory create --name "'.$smart_name.'" --kind smart --organization "'.$organization.'" --host-filter "groups__name='.$group.'"';
			print $smartinventory."\n" if ($debug);
			print "Adding Smart Inventory:$smart_name gor group $group\n";
			$cmd=$smartinventory;
			$ret=`$cmd`;
		}
   }		#print $smartinventory."\n".$smartinventory_flag."\n";exit;
}
get_group_id($inventory_id,'');
thread_print_progress("- All Groups Added",$gtotal,$gtotal) if ($gtotal>0);

#calculate ammount of work to track progress
	$progress=1;
	#$htotal = $#{ $hoststable{$ostype}{hosts} } +1;
	#$thread_counter = $#{ $hoststable{$ostype}{hosts} };
	$thread_counter = (keys %{ $idcontroltable{host} }) / 2;

	#call threads, create all hosts ,associate with their groups
	thread_call($inventory_id);

return "";
}

#convert json format to be used by tower-cli on windows
sub convert_windows_var{
my ($json_input)=@_;
#default	'{"ansible_ssh_common_args":"-o stricthostkeychecking=no -o userknownhostsfile=/dev/null -o proxycommand=\"connect-proxy -s 127.0.0.1:{{ jh_socks_port }} %h %p\""}'
#windows	"{\"ansible_ssh_common_args\":\"-o stricthostkeychecking=no -o userknownhostsfile=/dev/null -o proxycommand=\\\"connect-proxy -s 127.0.0.1:{{ jh_socks_port }} %h %p\\\"\"}"
$json_windows=$json_input;

#if additional conversion cases are found add them here
$json_windows =~ s/\\"/#@##@#/g; #save it on impossible sequence for later conversion
#$json_windows =~ s/\\/\\\\/g; #\ -> \\
$json_windows =~ s/"/\\"/g; #" -> \"
$json_windows =~ s/#@##@#/\\\\\\"/g; #escaped quote \" -> \\\"
#print Dumper $json_input;
#print Dumper $json_windows;
#exit;
return $json_windows;
}

sub read_xlsxgroups{
my ($filename,$sheetname)= @_;

print "\n--Reading TAB $sheetname of file: $filename\n" if ($verbose);

#use Text::Iconv;
#use utf8;
#my $converter = Text::Iconv -> new ("latin1","utf-8");
# Text::Iconv is not really required.
# This can be any object with the convert method. Or nothing.

$excel = Spreadsheet::XLSX -> new ($filename);#, $converter);

$sheet = $excel->worksheet($sheetname);
#check if tab exists
	if (!defined ($sheet->{Name})){
		die "Tab $sheetname not existent in file $filename. Case sensitive!\n";
	}

#check if excel formati is right
if(($sheet -> {MinCol} > $sheet -> {MaxCol})||($sheet -> {MaxRow} == 0)){
	print Dumper $sheet if ($debug >= 3);
	die "$sheetname TAB is empty OR this file has been generated in the wrong format by a code.\nTry to reopen it with excel like tool and just re-save it.\n";
}

#fill in column numbers
foreach my $col ($sheet -> {MinCol} ..  $sheet -> {MaxCol}) {
	my $cell = $sheet -> {Cells} [0] [$col];
	if ($cell) {
		#printf("( %s , %s ) => %s\n", 0, $col, $cell -> {Val});
		$column_name=lc($cell->{Val});
		if (defined($spreadsheet_group_columns{$column_name})){
			$spreadsheet_group_columns{$column_name}{column_number}=$col;
		}
		else{
			print "Discarded:$column_name\n" if ($debug >= 3);
		}
	}
}

#if there are any mandatory columns not present abort
foreach $key (keys %spreadsheet_group_columns){
	if ($spreadsheet_group_columns{$key}{column_number} eq 'NA' && $spreadsheet_group_columns{$key}{mandatory}){
		$abort_flag=1;
		print "Mandatory column not found: $key\n";
	}
}



print Dumper \%spreadsheet_group_columns  if($debug >= 2); #to check columns

  if ($abort_flag){ #abort if anything missing
	  print STDERR "Aborting...\n";
	  exit 1;
  }


#read entire tab make consistency checks
foreach my $row ( 3 .. $sheet -> {MaxRow}) { #group is always on row 3 -> row 0-2 are the headers

	foreach $data (keys %spreadsheet_group_columns){
		$data_content=''; #default is empty

		#column_number  => 'NA/Number' NA when columns does not exist and was not mandatory, previously checked
		if ($spreadsheet_group_columns{$data}{column_number} ne 'NA'){
			#get_data from cell
			$data_content=$sheet->{Cells} [$row] [$spreadsheet_group_columns{$data}{column_number}] -> {Val};
			$data_content='' if(!defined($data_content));

			$data_content=sup_reencode_correction($data_content);

			#mandatory  => 0/1, if mandatory but empty complain
			if ($spreadsheet_group_columns{$data}{mandatory} && $data_content eq '' ){
				$abort_flag=1;
				print "-Mandatory Column $data is empty at row/col: ".($row+1)."/".($spreadsheet_group_columns{$data}{column_number} +1)."\n\n";
			}
			$data_content=lc(sup_trim($data_content)); #trim data_content, spaces begin/end
			$groupcategory=$data_content if($data eq $groups_category_header);
			$groupname_custom=$data_content if($data eq $groups_name_header);
			$mgroup_var=$data_content if($data eq $groups_mandatoryvars_header);
			$egroup_var=$data_content if($data eq $groups_extravars_header);
			$muser_input=$data_content if($data eq $groups_mandatory_user_inputs_header);
	      }
	}
        if($groupcategory eq 'proxy groups' && !$mgroup_var ){
            $abort_flag=1;
            print "Mandatory variables not found at row ".($row+1)." for category $groupcategory.\n";
        }
        if($groupcategory eq 'credential groups' && !$mgroup_var ){
            $abort_flag=1;
            print "Mandatory variables not found at row ".($row+1)." for category $groupcategory.\n";
        }
        if($groupcategory eq 'proxy groups' && !$muser_input ){
            $abort_flag=1;
            print "Mandatory variables not found at row ".($row+1)." for category $groupcategory.\n";
        }
        if($groupcategory eq 'credential groups' && !$muser_input ){
            $abort_flag=1;
            print "Mandatory variables not found at row ".($row+1)." for category $groupcategory.\n";
        }
        if($groupcategory eq 'proxy groups' && $mgroup_var !~ /^jumphost_credential\s*:\s*'(.*?)'/){
            $abort_flag=1;
            print "Invalid mandatory variables found at row ".($row+1)." for category $groupcategory. Got \"$mgroup_var\", expected format: jumphost_credential:'jumphost_credential_name'\n";
        }
        if(!$credcheck && $groupcategory eq 'proxy groups'){
           my $cred_name='';
           $mgroup_var =~ /jumphost_credential\s*:\s*'(.*?)'.*/;
           $cred_name=$1;
           $cmd=`tower-cli credential get --name $cred_name 2>&1`;
           if($cmd =~ /Error/i){
             print "Jumphost Credential $cred_name does not exists in tower. Please make sure it exists before using it. Row : ".($row+1)." for $groupcategory in groups tab\n";
             $abort_flag=1;
           }
        }

        if($groupcategory eq 'credential groups' && $mgroup_var !~ /^os_credential\s*:\s*'(.*?)'/){
            $abort_flag=1;
            print "Invalid mandatory variables found at row ".($row+1)." for category $groupcategory. Got \"$mgroup_var\", expected format: os_credential: 'os_credential_name'\n";
        }
        if(!$credcheck && $groupcategory eq 'credential groups'){
           my $cred_name='';
           $mgroup_var =~ /os_credential\s*:\s*'(.*?)'.*/;
           $cred_name=$1;
           $cmd=`tower-cli credential get --name $cred_name 2>&1`;
           if($cmd =~ /Error/i){
             print "OS Credential $cred_name does not exists in tower. Please make sure it exists before using it. Row : ".($row+1)." for $groupcategory in groups tab\n";
             $abort_flag=1;
           }
        }

        if($groupcategory eq 'credential groups'){
          if($muser_input =~ /win|windows/i){
            $mgroup_var.=",".$win_con;
          }else{
            $mgroup_var.=",".$linux_con;
          }
        }
         if($groupcategory eq 'proxy groups'){
           if ($muser_input == 1){
             $mgroup_var.=",".$one_hop;
           }elsif($muser_input == 2){
             $mgroup_var.=",".$two_hop;
           }elsif($muser_input == 3){
             $mgroup_var.=",".$three_hop;
           }elsif($muser_input == 4){
             $mgroup_var.=",".$four_hop;
           }elsif($muser_input == 5){
             $mgroup_var.=",".$five_hop;
           }else{
             $abort_flag=1;
            print "Invalid hop value in mandatory columns found at row ".($row+1)."\n";
           }
         }
        
	#after getting all columns proceed updating row info
	$varstosend=process_group_columns($groupcategory,$groupname_custom,$mgroup_var,$egroup_var,$row+1);

	#check consistency and add group variable to list
	add_groupvar($groupname,$varstosend) if (!$abort_flag);

}#foreach row ends

  if ($abort_flag){ #some issue, abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

}

#read xlsx hosts tab
sub read_xlsxhosts{
my ($filename,$sheetname)= @_;
#my $varstosend;
print "\n--Reading TAB $sheetname of file: $filename\n" if ($verbose);

# Text::Iconv is not really required.
# This can be any object with the convert method. Or nothing.

$excel = Spreadsheet::XLSX -> new ($filename);#, $converter);

$sheet = $excel->worksheet($sheetname);
#check if tab exists
	if (!defined ($sheet->{Name})){
		die "Tab $sheetname not existent in file $filename. Case sensitive!\n";
	}

#fill in column numbers based on header
foreach my $col ($sheet -> {MinCol} ..  $sheet -> {MaxCol}) {
	my $cell = $sheet -> {Cells} [$header_row_hosts] [$col];
	if ($cell) {
		#printf("( %s , %s ) => %s\n", 0, $col, $cell -> {Val});
		$column_name=lc($cell->{Val});
		if (defined($spreadsheet_host_columns{$column_name})){
			$spreadsheet_host_columns{$column_name}{column_number}=$col;
		}
		else{
			print "Discarded:$column_name\n" if ($debug >= 3);
		}
	}
}

print Dumper \%spreadsheet_host_columns if ($debug >=3);

#if there are any mandatory columns not present abort
foreach $key (keys %spreadsheet_host_columns){
	if ($spreadsheet_host_columns{$key}{column_number} eq 'NA' && $spreadsheet_host_columns{$key}{mandatory}){
		$abort_flag=1;
		print "Mandatory column not found: $key\n";
	}elsif($spreadsheet_host_columns{$key}{column_number} eq 'NA' && $verbose){
		print "NON Mandatory column not found: $key\n";
	}
}

  if ($abort_flag){ #at the end list all the OStypes not matching and abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

#read entire tab
$host_count=1; #this is to index hosts in idcontroltable

#for each row in the spredsheet
foreach my $row ( ($header_row_hosts+1) .. $sheet -> {MaxRow}) {
	print "-Checking row ".($row+1)."\n" if ($debug >=3);
	#the way we control inventory is either hostname or ip. set it here
	$inventory_host=lc($sheet->{Cells} [$row] [$spreadsheet_host_columns{$default_data}{column_number}] -> {Val}) if $sheet->{Cells} [$row] [$spreadsheet_host_columns{$default_data}{column_number}] -> {Val};
	$ipaddress=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_ip_header}{column_number}] -> {Val};
	$connection_address=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_connectionaddress_header}{column_number}] -> {Val};
	$tier=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_tier_header}{column_number}] -> {Val};
	$device_type=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_devicetype_header}{column_number}] -> {Val};
	$os_type=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_ostype_header}{column_number}] -> {Val};
	$blk_event=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_blacklisted_event_header}{column_number}] -> {Val};
	$blk_bigfix=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_blacklisted_bigfix_header}{column_number}] -> {Val};
	$blk_scan=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_blacklisted_patchscan_header}{column_number}] -> {Val};
	$acc_event=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_access_event_header}{column_number}] -> {Val};
	$acc_bigfix=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_access_bigfix_header}{column_number}] -> {Val};
	$acc_scan=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_access_patchscan_header}{column_number}] -> {Val};
	$host_action=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$hosts_action_header}{column_number}] -> {Val};
        
        if(defined($host_action) && $host_action =~ /remove/i){push @decom_hosts, $inventory_host;next;}
        if(defined($host_action) && $host_action =~ /update/i){push @decom_hosts, $inventory_host;}

        #check if fqdn is defined
        if(!$inventory_host){push  @not_defined_fqdn, "Skipping  row no. $row as fqdn is not defined\n";  next;}

        #Check for invalid ips
        if(!$ipaddress){push  @invalid_ips, "Skipping host $inventory_host as ipaddress field is empty on row $row.\n";  next;}
        if(!$connection_address){push  @invalid_ips, "Skipping host $inventory_host as conection address field is empty on row $row.\n";  next;}
        if($ipaddress =~ /127\.0\.0\..*|0\.0\.0\.0/){push @invalid_ips, "Skipping host $inventory_host with rouge ipaddress '$ipaddress' on row $row\n";next;}
        if($connection_address  =~ /127\.0\.0\..*|0\.0\.0\.0/){push @invalid_ips, "Skipping host '$inventory_host' with rouge connection ipaddress '$connection_address' on row $row\n";next;}


        #Check for invalid os types
        if(!$os_type){push  @invalid_ostypes, "Skipping host $inventory_host as ostype field is empty on row $row.\n";  next;}
        $os_type=lc($os_type);
        if($os_type !~ /$supported_os_types/i){push @invalid_ostypes, "Skipping host $inventory_host as ostype '$os_type' is not supported on row $row\n";next;}


        #Check for invalid tiers
        if(!$tier){push  @invalid_tiers, "Skipping host $inventory_host as tier field is empty on row $row.\n";  next;}
        if($tier !~ /$group_check_regex/i){ push  @invalid_tiers, "Skipping host $inventory_host as Invalid tier '$tier' found on row $row.\n";  next;}
        
        #check for invalid device types
        if(!$device_type){push  @invalid_device_types, "Skipping host $inventory_host as device type field is empty on row $row.\n";  next;}
        if($device_type !~ /$supported_device_types/i){ push  @invalid_device_types, "Skipping host $inventory_host as Invalid device type '$device_type' found on row $row.\n";  next;}

	print "-Reading $inventory_host data...\n" if ($debug);
	$varstosend=''; #default is empty

	#Investigate each column for a match - since they might be in any order in the xlsx
	foreach $data (keys %spreadsheet_host_columns){
          $data_content=''; #default is empty

	  #column_number  => 'NA/Number' NA when columns does not exist and was not mandatory(previously checked)
	  if($spreadsheet_host_columns{$data}{column_number} ne 'NA'){
            #get_data from cell
             $data_content=$sheet->{Cells} [$row] [$spreadsheet_host_columns{$data}{column_number}] -> {Val};
             $data_content='' if(!defined($data_content));
	     #process column info, vars are being appendend
             #Convert if os type is win to windows
	     if($os_type eq "win" && $data eq "ostype"){
               $data_content = "windows";
             }


          # if($data eq "blacklist for events"){
          #   if( (defined($blk_event)) && (defined($acc_event)) && $blk_event =~ /\s*Y\s*/i && $acc_event =~ /\s*Y\s*/i){
          #    $data_content = "N" ;
          # push @blacklist_conflicts,"Found blacklist event and access event as 'Y' for $inventory_host on row $row. Access event has higher priority. So server will not be blacklisted.\n";
          # }
          #}

          if($data eq "blacklist for events"){if(!(defined($blk_event)) || $blk_event !~ /\s*Y\s*/i){$data_content = "N";}}
          if($data eq "blacklist for hc"){if(!(defined($blk_bigfix)) || $blk_bigfix !~ /\s*Y\s*/i){$data_content = "N";}}
          if($data eq "blacklist for patchscan"){if(!(defined($blk_scan)) || $blk_scan !~ /\s*Y\s*/i){$data_content = "N";}}

          if($data eq "access group for event"){
            if (!(defined($acc_event))){
              $data_content = "Y";
            }elsif ($acc_event =~ /Y|^\s*$/i){
              $data_content = "Y";
            }else{
              $data_content = "N";
            }
          }

          if($data eq "access group for hc"){
            if (!(defined($acc_bigfix))){
              $data_content = "Y";
            }elsif ($acc_bigfix =~ /Y|^\s*$/i){
              $data_content = "Y";
            }else{
              $data_content = "N";
            }
          }

          if($data eq "access group for patchscan"){
            if (!(defined($acc_scan))){
              $data_content = "Y";
            }elsif ($acc_scan =~ /Y|^\s*$/i){
              $data_content = "Y";
            }else{
              $data_content = "N";
            }
          }

          $data_content=sup_reencode_correction($data_content);
          ($varstosend,$host_count)=process_host_columns($data_content,$data,$row+1,$host_count,$inventory_host,$varstosend);
	}#end of: if columns exists (!=NA)
     }#end of column matcher for row analysis

	#add host variable to array to avoid --host and inclusion of whole inventory in host variable. Must add even if empty var
	add_meta_hostvar($inventory_host,$varstosend);

}#end of sheet rows foreach

  if ($abort_flag){ #at the end list all the OStypes not matching and abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

}

#process all group related decisions
sub process_group_columns{
my ($groupcategory,$groupname_custom,$mgroup_var,$egroup_var,$row_number)= @_;

	#build inventory groupname
#	if (defined($grouptype_category_values{$groupcategory})){
		#print "ola $groupcategory:".$grouptype_category_values{$groupcategory}.":\n";
#		$groupname=$organization."_grp_".$grouptype_category_values{$groupcategory}."_".$groupname_custom;
#	}else{
#		print "-Invalid category \"$groupcategory\" found in GROUPS tab row:".$row_number.", please check CACF docs for more details\n\n";
#		$groupname=$groupname_custom;
#		$abort_flag=1;
#	}

          if(($groupcategory =~ /proxy groups/) && ($groupname_custom !~ /${organization}_grp_/)){
             $groupname_custom=$organization."_grp_sshproxy_".$groupname_custom
          }elsif(($groupcategory =~ /credential groups/) && ($groupname_custom !~ /${organization}_grp_/)){
             $groupname_custom=$organization."_grp_cred_".$groupname_custom
          }elsif(($groupcategory =~ /user defined/) && ($groupname_custom !~ /${organization}_grp_/)){
             $groupname_custom=$organization."_grp_ud_".$groupname_custom
          }
	$groupname=$groupname_custom;
	print "--Read row ".$row_number.":$groupname:$mgroup_var\n" if($debug >= 2);

	#validate name standards
	#$is_valid=validate_standard($groupname,"groupname"); #send content and column_name
	#if(!$is_valid){
	#	$abort_flag=1;
	#	print "-Invalid groupname format for \"$groupname\" found in GROUPS tab row:".$row_number.", please check CACF docs or run -v for more details\n\n";
	#}

	#determine group type
	#$grouptype=validate_group_pattern_type($groupname);

	#if groupname is either proxy or credential check variable NAME pattern
	#if ($grouptype =~ /cred|sshproxy/i){
	#  $is_valid=validate_standard($grouptype.'#'.$mgroup_var,"proxycredvarpattern");
	#  if(!$is_valid){
	#  $abort_flag=1;
	#   print "-Invalid variable pattern format for \"$groupname_custom\" type \"$groupcategory\" row ".$row_number." found in GROUPS tab , please check CACF docs or run -v for more details\n\n";
	#  }
	#}

	#Compose given variable in expected group var format
	$varstosend=''; #default is empty

	#mandatory ones
	if(defined($mgroup_var)){
		$varstosend=$mgroup_var;# if($spreadsheet_group_columns{variables}{column_number} ne 'NA'); #if not empty
	}
	#extra ones
	if(defined($egroup_var)){
		if ($varstosend eq ''){
			$varstosend=$egroup_var;
		}else{
			$varstosend.=",".$egroup_var;
		}
	}

	#Add group to list of creation
	$idcontroltable{group}{$groupname}{id}='NA'; #set id NA for now
	#$idcontroltable{group}{$groupname}{type}=$grouptype; #set group type for future use

return $varstosend;
}

#process all host related decisions
sub process_host_columns{
my ($data_content,$data,$row_number,$host_count,$inventory_host,$varstosend)= @_;

#if empty, regardless its mandatory but there is a default, set it
#default => "anyvalue"
if ($data_content eq '' && defined($spreadsheet_host_columns{$data}{default})){
$data_content=lc($spreadsheet_host_columns{$data}{default});
}


if ( $data eq $hosts_hostvar_header){
  $data_content=(sup_trim($data_content)); #trim data_content, spaces begin/end
}else{
  $data_content=lc(sup_trim($data_content)); #trim data_content, spaces begin/end
}

#mandatory  => 0/1, if mandatory but empty cell complain
if ($spreadsheet_host_columns{$data}{mandatory} && $data_content eq '' ){
$abort_flag=1;
print "Mandatory Column $data is empty at row/col: ".$row_number."/".($spreadsheet_host_columns{$data}{column_number} +1)."\n";
}

print "Data:$data_content: at row: ".$row_number." , column: ".($spreadsheet_host_columns{$data}{column_number} +1)." ($data)\n" if ($debug >=3);

#validate standards for the column name (check if name is ok with standards for that column)
$is_valid=validate_standard($data_content,$data); #send content and column_name
if(!$is_valid){
$abort_flag=1;
print "Invalid $data format at row/col: ".$row_number."/".($spreadsheet_host_columns{$data}{column_number} +1)." .Check CACF docs or run -v for more details\n";
}

#security check for column hosts_organization_header
if ($data eq $hosts_organization_header){#if checking organization column
  if ($organization ne $data_content){
    $abort_flag=1;
    print "Invalid $data format at row/col: ".$row_number."/".($spreadsheet_host_columns{$data}{column_number} +1)." . $data must be: $organization\n";
  }
}

#create_var_host => 'var_name/N/VAR_LIST' only skip if N
if($spreadsheet_host_columns{$data}{create_var_host} ne 'N'){
  if($spreadsheet_host_columns{$data}{create_var_host} eq 'VAR_LIST'){ #in this case receives a list of already defined of variables
    if($varstosend eq ''){ #if still new dont add separator
      $varstosend=$data_content if($data_content !~ /^\s*$/);
    }else{
      $varstosend=$varstosend.",".$data_content if($data_content !~ /^\s*$/);
    }
  }else{ #use whatever var name was defined
    $tempvar=$spreadsheet_host_columns{$data}{create_var_host}.":"."'".$data_content."'";
    if($varstosend eq ''){ #if still new dont add separator
      $varstosend=$tempvar;
    }else{
      $varstosend=$varstosend.",".$tempvar;
    }
  }
}

#create_group => 'Y/N' ######################
if (($spreadsheet_host_columns{$data}{create_group} eq 'Y') ||($data eq $hosts_ostype_header)||($data eq $hosts_tier_header) || ($spreadsheet_host_columns{$data}{create_group} eq 'GROUP_LIST')){
  $group_received=''; #default is empty
	if (($spreadsheet_host_columns{$data}{create_group} eq 'Y') ){ #dont deal if ostype here
		$group_tmp=lc($data_content);

		#for the blacklist/access columns
		if($data =~ /$hosts_blacklisted_event_header|$hosts_tier_header|$hosts_ostype_header|$hosts_blacklisted_bigfix_header|$hosts_blacklisted_patchscan_header|$hosts_access_event_header|$hosts_access_bigfix_header|$hosts_access_patchscan_header/){
			$group_received=$organization."_grp_".$spreadsheet_host_columns{$data}{group_type} if($data_content =~ /y|yes/i);
                        if($group_tmp =~ /\/|-|\s/ && $data =~ /$hosts_ostype_header/i){
                          $group_tmp =~ s/\/|\s|-/_/g;
                        }
			$group_received=$organization."_grp_".$group_tmp if($data =~ /$hosts_ostype_header/i);
			$group_received=$organization."_grp_".$group_tmp if($data =~ /$hosts_tier_header/i);
		}else{ #any other group append data if it exists
			$is_valid=validate_standard($group_tmp,$hosts_groupmemberlist_header);
			if(!$is_valid){
				$abort_flag=1;
				print "Error on row ".$row_number.":Group list must be a comma separated list. Groups might only contain [A-Za-z0-9._] : $group_received\n";
			}
                        if(defined($group_tmp) && $group_tmp =~ /$group_check_regex/i ){
			  #$group_received=$organization."_grp_".$spreadsheet_host_columns{$data}{group_type};
			  #$group_received.="_".$group_tmp if($group_tmp ne '');
		          $group_received=$group_tmp if($group_tmp ne '');
                        }else{
		          $group_received=$group_tmp if($group_tmp ne '');
                        }
		}
	}elsif (($data eq $hosts_ostype_header)&&($spreadsheet_host_columns{$data}{create_group} eq 'Y')){	#if working on OStype then handle in a different way
		$group_tmp=lc(check_ostype_merge($data_content,$row_number-1));
		#$group_received=$organization."_grp_".$spreadsheet_host_columns{$data}{group_type}."_".$group_tmp;
		$group_received=$group_tmp;
	}elsif ($spreadsheet_host_columns{$data}{create_group} eq 'GROUP_LIST'){ #if its a group list
		#if working on mermbership list exists
		$group_received=lc($data_content) if (defined($data_content));

		#validate group list format empty|group|group,group[,group]
		$is_valid=validate_standard($group_received,$hosts_groupmemberlist_header);
		if(!$is_valid){
			$abort_flag=1;
			print "Error on row ".$row_number.":Group list must be a comma separated list. Groups might contain [a-z][0-9] : $group_received\n";
		}
	}
	@groups_list=split /,/, sprintf '%s', $group_received; #split the list in an array even if its a one item list;
	#print Dumper \@groups_list;

	foreach $group_creation (@groups_list){ #there may be one or many groups
		#first trim group name
		$group_creation=sup_trim($group_creation);

                  if(($data =~ /membership list|tier/) && ($group_creation !~ /${organization}_grp_/)){
                    $group_creation=$organization."_grp_ud_".$group_creation;
                  }elsif(($data =~ /proxygroup/) && ($group_creation !~ /${organization}_grp_/)){
                    $group_creation=$organization."_grp_sshproxy_".$group_creation;
                  }elsif(($data =~ /credentialgroup/) && ($group_creation !~ /${organization}_grp_/)){
                    $group_creation=$organization."_grp_cred_".$group_creation;
                  }

		#these groups are all userdefined so using ud pattern
		#if ($spreadsheet_host_columns{$data}{create_group} eq 'GROUP_LIST'){
		#	$group_tmp=$organization."_grp_"."ud"."_".$group_creation;
		#	$group_creation=$group_tmp;#put back in variable
		#}

		#validate group name standards
		$is_valid=validate_standard($group_creation,"groupname"); #send content and column_name
		if(!$is_valid){
			$abort_flag=1;
			print "Invalid groupname format for $group_creation ,HOSTS tab at row: ".$row_number." .Check CACF docs or run -v for more details\n";
		}

		#if groups already exists append Data/hosts list
		if (defined($hoststable{$group_creation}{hosts})){
			@hostsarray=@{$hoststable{$group_creation}{hosts}};
			#push to array if not already present
			 $present_already = grep (/^$inventory_host$/,@hostsarray);
			if (!$present_already){#if new host in that group
				push(@hostsarray,$inventory_host);
				$hoststable{$group_creation}{hosts}=[@hostsarray];
			}else{ #if duplicated
				print "Data ".$inventory_host." is duplicated. Same data in the same group \"$group_creation\", second appearance on row: ".$row_number."\n";# if($verbose || $debug || $towercli_flag);
				$abort_flag=1; #well this may be optional.. we can force it again. leave it aborting for now
			}
		}else{ #new group/ostype, etc
			undef @hostsarray; #clear it otherwise there will be garbage
			push(@hostsarray,$inventory_host);
			$hoststable{$group_creation}{hosts}=[@hostsarray];

			#create_var_group => 'var_name' only skip if N
			if($spreadsheet_host_columns{$data}{create_var_group} ne 'N'){
				#use whatever var name was defined
				$vargrouptosend=$spreadsheet_host_columns{$data}{create_var_group};#.":"."'".$data_content."'";
				add_groupvar($group_creation,$vargrouptosend);
			}
			#when dealing with new groups sent them to "all" list
			add_group_toall($group_creation);
		}

		#check group type built

		#if force_credproxy_grp_definition =1 we must garantee the group is defined in GROUP TAB already
		# if($force_credproxy_grp_definition && ($grouptype =~ /cred|sshproxy/i)){
		#$hosts_blacklisted_event_header|$hosts_blacklisted_bigfix_header|$hosts_blacklisted_patchscan_header|$hosts_access_event_header|$hosts_access_bigfix_header|$hosts_access_patchscan_header
		if($force_credproxy_grp_definition && ($group_creation !~ /_access_|_blacklist_|$group_check_regex|$supported_os_groups/i)){
	         	if (!defined($idcontroltable{group}{$group_creation}{id}) || ($idcontroltable{group}{$group_creation}{id} ne 'NA' )){
	        		$abort_flag=1;
	         	print "Group $group_creation must be defined in GROUPS TAB before using it. It is mentioned in hosts tab.\n";
		 	}
		 }

		#add to group control table
		$idcontroltable{group}{$group_creation}{id}='NA'; #set id NA for now
		# $idcontroltable{group}{$group_creation}{type}=$grouptype;

		#append group list to hosts, to be used by threads
		if (defined($idcontroltable{host}{$inventory_host}{groups})){ #append
			$grptmp=$idcontroltable{host}{$inventory_host}{groups};
                              #print "$group_creation\n";
                              #foreach $key1 (keys $idcontroltable{group}){
                              #print "Key: ".$key1."\n";
                              #}
			$idcontroltable{host}{$inventory_host}{groups}=$grptmp.",".$group_creation;
		}else{# create
			$idcontroltable{host}{$inventory_host}{groups}=$group_creation;
			$idcontroltable{host}{$host_count++}=$inventory_host; #use on threads to index by number, always increase one for next use
		}
	}#end of foreach

}#end of group creation ##########
return ($varstosend,$host_count);

}

sub read_csvgroups{
my ($filename)= @_;

print "\n--Reading file: $filename\n" if ($verbose);

our $csv = Text::CSV_XS->new ({
      binary    => 1,  # Allow special character. Always set this
      auto_diag => 1,  # Report irregularities immediately
      sep_char  => ',' # not really needed as this is the default
      });

open my $fh, "<", $filename or die "$filename: $!";

my $header = $csv->getline ($fh); #get only the first line
@header_array=@$header; #convert into array

$column_number=0;
#fill in column numbers
foreach my $col (@header_array) {
	#my $cell = $sheet -> {Cells} [0] [$col];
	if ($col) {
		#printf("( %s , %s ) => %s\n", 0, $col, $cell -> {Val});
		$column_name=lc($col);
		if (defined($spreadsheet_group_columns{$column_name})){
			$spreadsheet_group_columns{$column_name}{column_number}=$column_number;
		}
		#else{
		#	print "Discarded:$column_name\n";
		#}
	}
	$column_number++;
}

#if there are any mandatory columns not present abort
foreach $key (keys %spreadsheet_group_columns){
	if ($spreadsheet_group_columns{$key}{column_number} eq 'NA' && $spreadsheet_group_columns{$key}{mandatory}){
		$abort_flag=1;
		print "Mandatory column not found: $key\n";
	}
}

  if ($abort_flag){ #abort if anything missing
	  print STDERR "Aborting... Make sure csv header is in the first row\n";
	  exit 1;
  }

print Dumper \%spreadsheet_group_columns  if($debug >= 2); #to check columns

$row_number=2; #to count csv row in the loop so we can print errors
while (my $row = $csv->getline ($fh)) {
#read entire tab make consistency checks
#foreach my $row ( 1 .. $sheet -> {MaxRow}) { #group is always on row 1 -> row 0 is the header

@row_array=@$row; #convert into array

	foreach $data (keys %spreadsheet_group_columns){
		$data_content=''; #default is empty

		#column_number  => 'NA/Number' NA when columns does not exist and was not mandatory, previously checked
		if ($spreadsheet_group_columns{$data}{column_number} ne 'NA'){
			#get_data from cell
			#print "$spreadsheet_group_columns{$data}{column_number}\n";exit;
			$data_content=@row_array [$spreadsheet_group_columns{$data}{column_number}];
			$data_content='' if(!defined($data_content));

			$data_content=sup_reencode_correction($data_content);

			#print "----datacontent: $data_content\n";
			#mandatory  => 0/1, if mandatory but empty complain
			if ($spreadsheet_group_columns{$data}{mandatory} && $data_content eq '' ){
				$abort_flag=1;
				print "Mandatory Column $data is empty at row/col: ".$row_number."/".($spreadsheet_group_columns{$data}{column_number} +1)."\n";
			}

			$data_content=lc(sup_trim($data_content)); #trim data_content, spaces begin/end

			$groupcategory=$data_content if($data eq $groups_category_header);
			$groupname_custom=$data_content if($data eq $groups_name_header);
			$mgroup_var=$data_content if($data eq $groups_mandatoryvars_header);
			$egroup_var=$data_content if($data eq $groups_extravars_header);
			}
	}

	#after getting all columns proceed updating row info
	$varstosend=process_group_columns($groupcategory,$groupname_custom,$mgroup_var,$egroup_var,$row_number);

	#check consistency and add group variable to list
	add_groupvar($groupname,$varstosend) if (!$abort_flag);
	$row_number++;
}#while entire row ends
  close $fh; #close file

  if ($abort_flag){ #some issue, abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

}

sub read_csvhosts{
my ($filename)= @_;

print "\n--Reading file: $filename\n" if ($verbose);

our $csv = Text::CSV_XS->new ({
      binary    => 1,  # Allow special character. Always set this
      auto_diag => 1,  # Report irregularities immediately
      sep_char  => ',' # not really needed as this is the default
      });

open my $fh, "<", $filename or die "$filename: $!";

my $header = $csv->getline ($fh); #get only the first line
@header_array=@$header; #convert into array
$column_number=0;

#fill in column numbers based on header

#fill in column numbers
foreach my $col (@header_array) {
	#my $cell = $sheet -> {Cells} [0] [$col];
	if ($col) {
		#printf("( %s , %s ) => %s\n", 0, $col, $cell -> {Val});
		$column_name=lc($col);
		if (defined($spreadsheet_host_columns{$column_name})){
			$spreadsheet_host_columns{$column_name}{column_number}=$column_number;
		}
		#else{
		#	print "Discarded:$column_name\n";
		#}
	}
	$column_number++;
}

print Dumper \%spreadsheet_host_columns if ($debug >=3);

#if there are any mandatory columns not present abort
foreach $key (keys %spreadsheet_host_columns){
	if ($spreadsheet_host_columns{$key}{column_number} eq 'NA' && $spreadsheet_host_columns{$key}{mandatory}){
		$abort_flag=1;
		print "Mandatory column not found: $key\n";
	}elsif($spreadsheet_host_columns{$key}{column_number} eq 'NA' && $verbose){
		print "NON Mandatory column not found: $key\n";
	}
}

  if ($abort_flag){ #at the end list all the OStypes not matching and abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

#read entire tab
$host_count=1; #this is to index hosts in idcontroltable

#for each row in the spredsheet
$row_number=2; #to count csv row in the loop so we can print errors
while (my $row = $csv->getline ($fh)) {

@row_array=@$row; #convert into array

#foreach my $row ( ($header_row_hosts+1) .. $sheet -> {MaxRow}) {
	print "-Checking row ".$row_number."\n" if ($debug >=3);
	#the way we control inventory is either hostname or ip. set it here
	$inventory_host=lc(@row_array [$spreadsheet_host_columns{$default_data}{column_number}]);
	print "-Reading $inventory_host data...\n" if ($debug);
	$varstosend=''; #default is empty

	#Investigate each column for a match - since they might be in any order in the xlsx
	foreach $data (keys %spreadsheet_host_columns){
		$data_content=''; #default is empty

		#column_number  => 'NA/Number' NA when columns does not exist and was not mandatory(previously checked)
		if ($spreadsheet_host_columns{$data}{column_number} ne 'NA'){
			#get_data from cell
			$data_content=@row_array [$spreadsheet_host_columns{$data}{column_number}];
			$data_content='' if(!defined($data_content));

			$data_content=sup_reencode_correction($data_content);

			#process column info, vars are being appendend
			($varstosend,$host_count)=process_host_columns($data_content,$data,$row_number,$host_count,$inventory_host,$varstosend);

		}#end of: if columns exists (!=NA)
	}#end of column matcher for row analysis

	#add host variable to array to avoid --host and inclusion of whole inventory in host variable. Must add even if empty var
	add_meta_hostvar($inventory_host,$varstosend);
	$row_number++;
}#end of sheet rows foreach

  if ($abort_flag){ #at the end list all the OStypes not matching and abort
	  print STDERR"Aborting...\n";
	  exit 1;
  }

}


#prints items in Json format
sub print_screen_json {
#my ($print_flag)= @_;
#example {"devssc": {"hosts": ["devsscipmon01", "devsscapp01"]}}

#$json_ugly = encode_json \%hoststable; #this is the compact ugly version
#print $json_ugly."\n";

$json_instance = new JSON;
$json_instance->canonical(); #sort with some overhead
$json_pretty = $json_instance->pretty->encode(\%hoststable);

#print $json_pretty."\n";# if ($print_flag);;
return $json_pretty."\n";
}

#prints items in yaml format
sub print_screen_yaml {
#https://docs.ansible.com/ansible/latest/plugins/inventory/yaml.html
#undef %yamlhash;

foreach $ostype (keys %hoststable){
	#next if ($ostype eq "_meta"); #skip meta

}

return YAML::Dump(%hoststable);

#return $yaml."\n";
}

#prints items in Ini format
sub print_screen_ini {
#my ($print_flag)= @_;
$output="";
#print Dumper \%hoststable;
foreach $ostype (keys %hoststable){
	next if ($ostype eq "_meta"); #skip meta
	next if ($ostype eq "all"); #skip all

	#print "[$ostype]\n";
	$output=$output."[$ostype]\n";
	#print hosts and variables
	foreach $data (@{ $hoststable{$ostype}{hosts} }){
		#need to check _meta for host specific variables
		$gotvar_ref=$hoststable{_meta}{hostvars}{$data}; #get the reference to the hash
		%var_list = %{$gotvar_ref}; #rebuilt the hash
		$var_string='';
		foreach $var (keys %var_list){
			if ($var_list{$var} !~ /\s/){ #if there is no space in value eliminate single quote
				$singlequote="";
			}else{$singlequote="'";}
			$var_string=$var_string."$var=$singlequote".$var_list{$var}."$singlequote ";
		}
		#print "$data $var_string\n" if ($print_flag);
		$output=$output."$data $var_string\n";
	}
	#print groups variables
	if (defined ($hoststable{$ostype}{vars})){
		#print "[$ostype:vars]\n"; #print header
		$output=$output."[$ostype:vars]\n"; #print header
		$gotvar_ref=$hoststable{$ostype}{vars}; #get the reference to the hash
		%var_list = %{$gotvar_ref}; #rebuilt the hash
		foreach $var (keys %var_list){
			if ($var_list{$var} !~ /\s/){ #if there is no space in value eliminate single quote
				$singlequote="";
			}else{$singlequote="'";}
			#print "$var=$singlequote".$var_list{$var}."$singlequote\n" if ($print_flag);
			$output=$output."$var=$singlequote".$var_list{$var}."$singlequote\n";
		}
	}
}
return $output;
}

#Support Subs#####################

#remove trailing spaces left and right
sub sup_trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

#send result to terminal or file
sub sup_print_results{
my ($wholething)= @_;

	if (defined($result_file)){
		open my $fh, ">>", $result_file or die "error opening file: $!";
		print ($fh $wholething."\n");
		close $fh or die "error closing file: $!";
	}else {
		print "$wholething";
	}

}

#convert non utf-8 characters
#today only converting those found as an issue. If there are many in the future we might use external encode package
sub sup_reencode_correction{
my ($data_content)= @_;

	$data_content= decode_entities($data_content);
	$data_content=~ s/’/'/g;
	$data_content=~ s/‘/'/g; #yes thats a different char from the above one
	$data_content=~ s/\x{2019}/'/g;
	$data_content=~ s/\x{2018}/'/g;
	#$data_content= encode('utf-8',$data_content);
	#remove new line from any cell
	$data_content=~ s/\n//g;

return $data_content;
}

#find ostype
sub sup_check_os {
if ( $^O =~ /MSWin32/i ) {
	$os="windows";
}elsif ( $^O =~ /linux/i ){
	$os="linux";
}elsif ( $^O =~ /darwin/i ){
	$os="darwin";
}
else {
	print "Sup_check_os:$^O:Unknown, contact $admin\n";
	exit 1;
}
return $os;
}

#print xlsx defined format
sub usage_xlsx_format{
print "XLSX FORMAT SAVED IN MS EXCEL\n-hosts tab columns\n";
foreach my $column (sort { $spreadsheet_host_columns{$a} <=> $spreadsheet_host_columns{$b} } keys %spreadsheet_host_columns) {
    print "\"$column\", Mandatory=$spreadsheet_host_columns{$column}{mandatory};\t";
}

print "\n-groups tab columns\n";
foreach $column (sort keys %spreadsheet_group_columns){
	print "\"$column\", Mandatory=$spreadsheet_group_columns{$column}{mandatory};\t";

}
print "\n";
}

#verify if IP received is valid or not
sub sup_valid_ip{
my ($ip)= @_;
$stat=0;

if ( $ip =~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/ ){
        @ipsplit=(split /\./,$ip);
        $stat=1 if ( $ipsplit[0] <= 255 && $ipsplit[1] <= 255 && $ipsplit[2] <= 255 && $ipsplit[3] <= 255 );
}
return $stat;
}

#this is not called, its only for debug purposes to check what was the content read in the spreadsheet.Its commented out on main
sub sup_print_xlsx {
my ($excel,$sheetname)= @_;

$sheet = $excel->worksheet($sheetname);
if (!defined ($sheet->{Name})){
	die "Tab $sheetname not existent in file\n";
}
#print Dumper $sheet;exit;
printf("Sheet: %s\n", $sheet->{Name});
foreach my $row ($sheet -> {MinRow} .. $sheet -> {MaxRow}) {
	foreach my $col ($sheet -> {MinCol} ..  $sheet -> {MaxCol}) {
		my $cell = $sheet -> {Cells} [$row] [$col];
		if ($cell) {
			printf("( %s , %s ) => %s\n", $row, $col, $cell -> {Val});
		}
	}
}
}

#only for debug may be called to pasrse json
sub sup_debug_json_decode() {
	print "Decode of server\n";
#group var
$myHashEncoded='{
    "all": {
        "hosts": []
    },
    "_meta": {
        "hostvars": {
            "10.1.3.2": {},
            "10.1.3.5": {}
        }
    },
    "Linux": {
        "hosts": [
            "10.1.3.2",
            "10.1.3.5"
        ],
        "children": [],
        "vars": {
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand=\"connect-proxy -S 127.0.0.1:{{ jh_socks_port }} %h %p\""
        }
    }
}';
my $myHashRefDecoded = decode_json($myHashEncoded);
my %myHashDecoded = %$myHashRefDecoded;
print Dumper \%myHashDecoded;

}

sub delete_decom_hosts {
	@decom_hosts=@_;
	#Get the list of hosts from tower for the account name
        if (defined($inventory_name)){
         $inventory_name=$inventory_name;
       }else{
         $inventory_name=$organization."_inventory";
       }
    #$cmd="tower-cli host list -a --inventory ".$inventory_name." 2>/dev/null|grep -v '=='|grep -v 'name'|awk '{print \$2}'";
    #@hostlist=`$cmd`;
    @hostlist=grep(!/^==/ && !/RuntimeWarning/ && !/id[ ]*name[ ]*inventory[ ]*enabled/ ,`tower-cli host list -i $inventory_name -a 2>&1`);
    @hostlist=map { (split ' ', $_)[1] } @hostlist;
  foreach $decom_host (@decom_hosts){
      chomp $decom_host;
      $decom_host=sup_trim($decom_host);
      if ( grep { $_ =~ /^$decom_host$/} @hostlist )
      {
         #$output=`tower-cli host delete --name $decom_host --inventory $inventory_name 2>/dev/null`;
         @output=grep(!/RuntimeWarning/,`tower-cli host delete --name $decom_host --inventory $inventory_name 2>&1`);
         $output=join "",@output;
         chomp $output;
         if ($output eq 'OK. (changed: true)')
         {
           print "$decom_host deleted successfully from tower inventory $inventory_name.\n";
         }else{
           print "Error in deleting the $decom_host from $inventory_name inventory\n";
           print "$output";
           print "Please fix the issue in tower and retry the script\n";
           print "If you get 'Resource is being used by running jobs' error, please retry the script after sometime\n";
           exit;
         }
      }else{
        print "Host: $decom_host does not exists in tower\n";
      }
 }
}

sub check_tower_access {
my($org,$inventory)=@_;
#@towerconfig=`tower-cli config`;
@towerconfig=grep(!/RuntimeWarning/,`tower-cli config 2>&1`);

@full_token=grep (/oauth_token/,@towerconfig);
@splitted=split / /, $full_token[0];
$token=$splitted[1];
$token =~ s/\n//g;
if(!$token){
  print "Token not defined in \"tower-cli config\" \n";
  exit;
}

@full_name=grep (/username/,@towerconfig);
@splitted_name=split / /, $full_name[0];
$name=$splitted_name[1];
$name =~ s/\n//g;

if(!$name){
  print "Username not defined in \"tower-cli config\" \n";
  exit;
}
@full_host=grep (/host/,@towerconfig);
@splitted_host=split / /, $full_host[0];
$host=$splitted_host[1];
$host =~ s/\n//g;
if(!$host){
  print "Tower host not defined in \"tower-cli config\" \n";
  exit;
}
print "Checking access levels for id: $name in tower : $host\n";
#https://ansible-tower-web-svc-ansible-tower-new.cloudapps.pt.ibm.com/api/v2/users/1197/admin_of_organizations/
#https://ansible-tower-web-svc-ansible-tower-new.cloudapps.pt.ibm.com/api/v2/inventories/114/access_list/


#Get userid from tower
@user_id=grep(!/^==/ && !/RuntimeWarning/ && !/id[ ]*username[ ]*email[ ]*first_name[ ]*last_name[ ]*is_superuser[ ]*is_system_auditor/ ,`tower-cli user get  $name 2>&1`);
@user_id1=split ' ', $user_id[0];
$uid=$user_id1[0];
if($uid =~ /^Error/i){
 print "Error in getting user details from tower\n";
 print "@user_id\n";
 exit;
}

#Get inventory id from tower
#tower-cli inventory get --name www_inventory --organization www
@inventory_id=grep(!/^==/ && !/RuntimeWarning/ && !/id[ ]*/ ,`tower-cli inventory get  --name $inventory --organization $org 2>&1`);
@inventory_id1=split ' ', $inventory_id[0];
$invid=$inventory_id1[0];
if($invid =~ /^Error/i){
 print "Error in getting inventory  details from tower\n";
 print "@inventory_id\n";
 exit;
}

$admin_org="curl -X GET -k -s -H \"Authorization: Bearer $token\" $host/api/v2/users/$uid/admin_of_organizations/ 2>&1";
$admin_org =~ s/\/\//\//g;
$admin_org =~ s/https:\/(\w+)/https:\/\/$1/g;
$admin_org=`$admin_org`;
if($admin_org =~ /^Error/i){
 print "Error in getting organizations details from tower\n";
 print "$admin_org\n";
 exit;
}
$json = JSON->new->allow_nonref;
my $decoded_json = $json->decode( $admin_org );
$res=$decoded_json->{results};
my @orgs='';
#foreach $key (keys %$decoded_json->{'results'}){
foreach $key (keys @$res){
 push(@orgs,$decoded_json->{results}[$key]->{name})
}

@is_admin = grep (/^$org$/,@orgs);
if(!@is_admin){
  $access_list="curl -X GET -k -s -H \"Authorization: Bearer $token\" $host/api/v2/inventories/$invid/access_list/ 2>&1";
  $access_list =~ s/\/\//\//g;
  $access_list =~ s/https:\/(\w+)/https:\/\/$1/g;
  $access_list=`$access_list`;
  $json = JSON->new->allow_nonref;
  my $decoded_json1 = $json->decode( $access_list );
  my $res1=$decoded_json1->{results};
  my @usernames='';
  foreach $key (keys @$res1 ){
   push(@usernames,$decoded_json1->{results}[$key]->{username})
  }
  
  @is_user_present = grep (/$name/,@usernames);
  if(!@is_user_present){
    print "ID: $name do not have proper access in tower $host to run this script\n"; 
    print "You have to be either inventory admin or org admin. Neither of it is present\n";
    exit 1;
  }

  foreach $key (keys @$res1){
    if($decoded_json1->{results}[$key]->{username} =~ /$name/){
      $is_admin_direct=$decoded_json1->{results}[$key]->{summary_fields}{direct_access}[0]->{role}{name};
      if(!$is_admin_direct){
        $is_admin_direct="empty";
      }

      $is_admin_indirect=$decoded_json1->{results}[$key]->{summary_fields}{indirect_access}[0]->{role}{name};
      if(!$is_admin_indirect){
        $is_admin_direct="empty";
      }
      if($is_admin_direct eq "Admin" || $is_admin_indirect eq "System Administrator"){
          print "ID: $name has inventory admin access in tower $host \n";
      }else{
          print "ID: $name do not have proper permissons to run this script\n"; print "You have to be either inventory admin or org admin. Neither of it is present in $host\n";exit 1;
    }
   }
}
}else{
  print "ID: $name has organization admin access in tower $host \n";
}
print "######################################\n";
} #END of sub check_tower_access
sub delete_hosts {
  print "These hosts will be deleted:\n";
  my(@decom_servers)=@_;
  foreach $h(@decom_servers){
    print "$h\n";
  }
}
#Main#############################

#Verify arguments
Getopt::Long::Configure ('bundling');
GetOptions ('h|help' => \$help,
            'v|verbose' => \$verbose,
            'j|json' => \$json_flag,
            'y|yaml' => \$yaml_flag,
            'o|organization=s' => \$organization,
            'm|maxthreads=s' => \$ud_threads,
            'k|hosts-file=s' => \$hosts_file,
            'g|groups-file=s' => \$groups_file,
            'i|inventoryname=s' => \$inventory_name,
	    'f|file=s' => \$force_report,
	    'w|overwrite' => \$overwrite,
	    'b|tiergroup' => \$tiergroup,
	    'c|ostypegroup' => \$ostypegroup,
	    'a|credcheck' => \$credcheck,
            'd|debug' => \$debug) or exit 1;

$help && usage();
#!$csvfile && usage();
$debug=0 if(!$debug);
$overwrite=1 if($overwrite);
$spreadsheet_host_columns{$hosts_tier_header}{create_group}='N' if($tiergroup);
$spreadsheet_host_columns{$hosts_ostype_header}{create_group}='N' if($ostypegroup);
$verbose=0 if(!$verbose);
$json_flag=0 if(!$json_flag);
$yaml_flag=0 if (!$yaml_flag);
$playbook_flag=0 if (!$playbook_flag);
$ini_flag=0 if(!$ini_flag);
#$credcheck=0 if(!$credcheck);
$usename_flag=0 if(!$usename_flag);
$smartinventory_flag=0 if(!$smartinventory_flag);
$csv_flag=0 if (!defined($csv_flag));
$reportdb_file=$force_report if(defined($force_report));

#Parameters consistency
#usage("-j and -t cant be combined") if ($json_flag && $towercli_flag);
usage("-j -z -y -p cant be combined") if (($json_flag + $ini_flag + $yaml_flag + $playbook_flag)>1);
usage("-j -z -y -p requires -o specified") if (($json_flag || $ini_flag || $yaml_flag || $playbook_flag) && !$organization);
usage("-c requires -o specified") if ($csv_flag && !$organization);
usage("-o required") if (!$organization);
usage("-m expects a number") if (defined($ud_threads) && $ud_threads !~ (/^\d+$/));
usage("Option -f cannot be combined with -k and -g ") if ($hosts_file && $groups_file && $force_report);
usage("Option -k needs to be used along with option -g ") if (defined($hosts_file) && !(defined($groups_file)));
usage("Option -g needs to be used along with option -k ") if (defined($groups_file) && !(defined($hosts_file)));
#usage("-t must be followed by print|import") if ($towercli_flag && $towercli_flag !~ /print|import/);

print "###################################################\n";
print "# Script version: $version                            #\n";
print "# Git: https://github.ibm.com/cacf/inventory_load #\n";
print "###################################################\n";
if (!$inventory_name){
  $inventory_name=$organization."_inventory";
}

#set user defined threads
if(defined($ud_threads)){
$maxthreads=$ud_threads;
print "Maxthreads changed to $maxthreads\n" if ($verbose);
}

$debug=$debug_level if ($debug);#if debug flag set it to debug_level


#test tower cli access
tower_cli_check();

#Check if user has inventory admin or org admin access
#check_tower_access($organization,$inventory_name);
#set ip to be the default information
$default_data = $hosts_ip_header if ($usename_flag);

#print bypass message if set
print "-Warning: Validation bypass is on, skipping...\n" if ($verbose && $bypass_namestandard_validation);

#load inventory id and organization name
if(!($json_flag || $ini_flag || $yaml_flag || $playbook_flag)){
	print "--Loading inventory and organization details...\n" if ($verbose);
        our $inventory_id=get_inventory_id($inventory_name);
	print "Ansible Tower associated organization: $organization" if ($verbose);
}


#basic consistency tests
if($groups_file && $hosts_file){
  test_components($hosts_file);
  test_components($groups_file);
}else{
  test_components($reportdb_file);
}

my $logfile=$organization."_inventory_create_errors.".$stamp.".log";
#open my $errors_file, ">", $organization."_inventory_create_errors.".$stamp.".log";
open my $errors_file, ">", $logfile;
if ($csv_flag){
	$groupsfile=$organization.'_'.$csv_groups_suffix;
	$hostsfile=$organization.'_'.$csv_hosts_suffix;
	#load csv
	print "--Loading files to memory: $groupsfile,$hostsfile\n" if ($verbose);
	#read groups first then hosts... to already double check groups
	read_csvgroups($groupsfile);
	read_csvhosts($hostsfile);
}else{
	#load xlsx file
	print "--Loading file to memory: $reportdb_file\n" if ($verbose);
	#read groups first then hosts... to already double check groups
        if ($hosts_file && $groups_file){
          print "Reading groups file\n";
	  read_xlsxgroups($groups_file,"GROUPS");
          print "Reading hosts file\n";
	  read_xlsxhosts($hosts_file,"HOSTS");
        }else{
          print "Reading groups tab\n";
	  read_xlsxgroups($reportdb_file,"GROUPS");
          print "Reading hosts tab\n";
	  read_xlsxhosts($reportdb_file,"HOSTS");
        }
        if ($json_flag || $yaml_flag || $playbook_flag || $ini_flag){
          delete_hosts(@decom_hosts) if(@decom_hosts);
          print "There are no hosts to be deleted\n" if !(@decom_hosts);
          print "-----------------\n";
        }else{
          delete_hosts(@decom_hosts) if(@decom_hosts);
          delete_decom_hosts(@decom_hosts) if(@decom_hosts);
          print "There are no hosts to be deleted\n" if !(@decom_hosts);
          print "-----------------\n";
        }
        if (defined($inventory_name)){
          $inventory_name=$inventory_name;
        }else{
          $inventory_name=$organization."_inventory";
        }
        #$host_names=`tower-cli host list -i $inventory_name -a|grep -v "=="|grep -v "enabled"|awk '{print \$2}' 2>&1`;
        @host_names=grep(!/^==/ && !/RuntimeWarning/ && !/id[ ]*name[ ]*inventory[ ]*enabled/ ,`tower-cli host list -i $inventory_name -a 2>&1`);
        @host_names = map { (split ' ', $_)[1] } @host_names;
        foreach my $host_names (@host_names) {
          if($host_names =~ /Error:/){
           print "Error in getting host list from tower. Please check the if tower-cli is working properly before running the script\n";
           print "$host_names\n";
           exit 1;
          }
        }
    #   @tower_hostnames=split /\n/, sprintf '%s', $host_names;
        @tower_hostnames=@host_names;
        print $errors_file "#############################\n";
        print $errors_file "#    NOT DEFINED FQDN   #\n";
        print $errors_file "#############################\n";
        print $errors_file @not_defined_fqdn;
        print $errors_file "\n";
        print $errors_file "#############################\n";
        print $errors_file "#    INVALID IP ADDRESSES   #\n";
        print $errors_file "#############################\n";
        print $errors_file @invalid_ips;
        print $errors_file "\n";
        print $errors_file "#############################\n";
        print $errors_file "#    INVALID OS TYPES       #\n";
        print $errors_file "#############################\n";
        print $errors_file "Valid OS types: $supported_os_types\n";
        print $errors_file @invalid_ostypes;
        print $errors_file "\n";
        print $errors_file "#############################\n";
        print $errors_file "#    INVALID TIERS          #\n";
        print $errors_file "#############################\n";
        print $errors_file "Valid tiers: $group_check_regex\n";
        print $errors_file @invalid_tiers;
        print $errors_file "\n";
        print $errors_file "#############################\n";
        print $errors_file "#    INVALID DEVICE TYPES   #\n";
        print $errors_file "#############################\n";
        print $errors_file "Valid device types: $supported_device_types\n";
        print $errors_file @invalid_device_types;
        print $errors_file "\n";
        print $errors_file "#################################################################\n";
        print $errors_file "#   DELETED DECOMMISSIONED HOSTS   #\n";
        print $errors_file "#################################################################\n";
        print $errors_file @decom_hosts;
        print $errors_file "\n";
}

print "-IDcontrolTable:\n" if($debug >= 2);
print Dumper \%idcontroltable if($debug >= 2);
print "-hoststable:\n" if($debug >= 2);
print Dumper \%hoststable if($debug >= 2);

#sup_debug_json_decode(); #debug only, comment that out

#call json print or import
if($json_flag||$playbook_flag){#just print in json
	$output=print_screen_json();
	if ($playbook_flag){ #json with additives
		sup_print_results("#!/bin/bash\necho '$output'\n");
	}else{ #pure json
		sup_print_results("$output\n");
	}
}elsif($yaml_flag){
	sup_print_results(print_screen_yaml());
}elsif($ini_flag){
	sup_print_results(print_screen_ini());
}else{#do the tower-cli
	print "--Preparing Import:\n" if ($verbose);
        call_inventory_vars_create();
	$output=call_towercli();#$inventory_name);
        print $errors_file "#############################\n";
        print $errors_file "#    HOST CREATION ERRORS   #\n";
        print $errors_file "#############################\n";
        print $errors_file @host_create_errors;
        print $errors_file "\n";
        print $errors_file "#############################\n";
        print $errors_file "# ALREADY PRESENT IN TOWER  #\n";
        print $errors_file "#############################\n";
        print $errors_file @hosts_skipped;
	print "Import Done!\n";
}
#system("cat ${organization}_inventory_create_errors.${stamp}.log");
close $errors_file;
open my $log, "<", $logfile or die "$logfile: $!";
print "Error and INFO LOG OUTPUT\n";
foreach $line(<$log>){
print $line;
}
print "-------------------------\n";
print "Errors are logged to $logfile\n";
