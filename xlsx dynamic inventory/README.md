# INVENTORY UPLOAD SCRIPT/UTILITY
ALWAYS DOWNLOAD and USE LATEST TEMPLATE (.xlsx) and the LATEST at-inventory-import.pl from this location
REFER to CACF INVENTORY MANAGEMENT STANDARDS: https://ibm.box.com/s/cufq72fee7gnybyd7ek6pbyx79w8akaz

## WHAT THIS SCRIPT DOES :<BR>
This tool creates and populates Ansible Tower Inventory following CACF Standards, which include creating OS and Proxy Credential Groups, configuring JumpHost, Socks & Connection variables(https://ibm.box.com/s/yzbae4zcpmorzvnv7sqth4ur6i3n2qtw) required for Tower to connect to target endpoints


##OVERVIEW OF THE TOOL FUNCTIONALITY<BR>
This script does the following things.

Checks if the user executing the script is org admin or inventory admin, if not then it quits.

Reads HOSTs TAB and does the following:
1. Deletes hosts from tower if action column in the hosts tab is 'remove'.
2. Deletes and recreates the host if action column in the hosts tab is 'update'. Note: Any custom hosts vars will get overwritten in this case.
3. Creates the host if the action columns in hosts tab is 'add' or is empty.
4. It checks for valid tier,ostype and devicetype for each host.
5. It skips creation of the host if it already exists.
6. It creates below host variables for each host.<BR>
    fqdn: {value from FQDN column} <BR>
    tier: {value from TIER column}<BR>
    ostype: {value from OSTYPE column}<BR>
    devicetype: {value from DEVICETYPE column}<BR>
    ansible_host: {value from connection address column}<BR>
    ipaddress: {value from ipaddress column}<BR>
    
    If any other extra variables are present in hostvarialbes column they will also be created.
    EG: os_sub_type: "windows 2016 server"
    
    If any other  variables are present in middleware variables column they will also be created.
    EG: middleware: "websphere 5.2"

7. It assosiates the host to below different groups.
    Groups based on ostype (xxx_grp_ud_ostype)
    Eg: xxx_grp_ud_windows<BR>

    Group based on tier (xxx_grp_ud_tier)
    Eg: xxx_grp_ud_development<BR>

    Group for connecting to jumphost  using the value from ProxyGroup column.
    Note: If value is 3hop in proxy group columns, the script will append it with xxx_grp_sshproxy
    Eg: xxx_grp_sshproxy_3hop<BR>

    Group for getting os credentials using the value from CredentialGroup column.
    Note: If value is wincred in credential group columns, the script will append it with xxx_grp_cred
    Eg: xxx_grp_cred_wincred<BR>

    Group for blacklisting events if value in 'BlackList for Events' column is 'Y'
    Eg: xxx_grp_blacklist_event<BR>

    Group for blacklisting patch scan if value in 'BlackList for PatchScan' column is 'Y'
    Eg: xxx_grp_blacklist_patchscan<BR>

    Group for blacklisting health check if value in 'BlackList for HC' column is 'Y'
    Eg: xxx_grp_blacklist_hc<BR>

    Adds to Group for access events if value in 'Access Group for Event' column is 'Y'
    Eg: xxx_grp_access_event<BR>

    Adds to Group for access patch scan if value in 'Access Group for PatchScan' column is 'Y'
    Eg: xxx_grp_access_patchscan<BR>

    Adds to Group for access health check if value in 'Access Group for HC' column is 'Y'
    Eg: xxx_grp_access_hc<BR>

Reads GROUPS TAB and does the following:<BR>
    1. Checks groups mentioned in proxy and credentail group columns in hosts are mentioned in groups tab under their respecitve categories.<BR>
    2. Checks if no of hops for proxy is mentioned or not.<BR>
    3. Checks if jumphost_credentail variable is mentioned or not for proxy group.<BR>
    4. Checks if os_credential is mentioned or not for credentail group.<BR>
    5. Creates all the groups if all the above conditions are met.<BR>
    6. Skips creation of the groups if they already exists in tower.<BR>


## TOOL INSTALLATION OVERVIEW :<BR>
##### This script/utility can be installed on your workstation OR on any server from where a connection can be established to Ansible Tower Server
1)Perl pre requisite<BR>
2)Python & Tower-cli pre requisite<BR>
3)Check installation<BR>

## Step1: PERL INSTALLATION ----
### Perl on LINUX Installation:<BR>
1a)sudo yum install perl-5 <BR>
hint: search for the package exact name using yum search perl-5<BR>

1b)try to install libraries if any not found use alternative solution<BR>
sudo yum install perl-Spreadsheet-XLSX perl-JSON perl-YAML perl-Text-CSV_XS<BR>

alternative solution:<BR>
extract file "libs_inventory_for_linux_ifneeded.tar.gz" (ATTACHED ABOVE) in same path as at-inventory-import.pl<BR>

### Perl on WINDOWS Installation:<BR>
1a)install strawberryperl 5.30 - http://strawberryperl.com/<BR>

(Approved: https://w3-connections.ibm.com/wikis/home?lang=en_US#/wiki/Wae20f867b263_4104_a617_15981cf26055/page/Current%20Listing%20of%20G2O%20Software)<BR>
  
You may receive a Cb Protection "blocked notification". In that case request approval using text "Need Windows Perl for Ansible Tower project inventory load process.". It might take a day for approval/confirmation.<BR>

1b)C:\> cpan Spreadsheet:XLSX<BR>

note: in case windows test fails extract file "libs_inventory_for_windows_ifneeded.zip" in the same path as at-inventory-import.pl<BR>

TEST step 1:<BR>
Linux: ./at-inventory-import.pl<BR>

Windows: at-inventory-import.pl OR perl at-inventory-import.pl<BR>

you shoud/must see the help content<BR>


## Step2: PYTHON & TOWER-CLI INSTALLATION ----  
### Python on Linux Installation:<BR>
2a)requires python 3.6  or greater if not yet installed<BR>
#ex: sudo yum install python<BR>

#install pip or pip3<BR>
sudo yum install python3-pip<BR>

2b)#Install Towerclient<BR>
#sudo pip/pip3 install --upgrade setuptools #if requested by pip<BR>
sudo pip3 install ansible-tower-cli #or pip depending on your environment<BR>

### Python on Windows Installation:<BR>

2a)Install python interpreter: https://www.python.org/downloads/windows/ -> Download Windows x86-64 executable installer (3.8.1)<BR>

2b)Open Admin c:\><BR>
python -m pip install --upgrade pip<BR>
pip install --upgrade setuptools #if requested by pip<BR>
pip install ansible-tower-cli<BR>


## Step3: CREATE OAUTH2.0 TOKEN  ----  

Login on Ansible tower with your userid<BR>
Go to ‘Users’<BR>
Search for your user id and click on it<BR>
On options above, click in ‘TOKENS’: <BR>
Click on plus sign: <BR>
Fill the form:<BR>
Application: keep in blank<BR>
Description: TOWER CLI<BR>
Scope: Write<BR>
Save<BR>

SAVE the token it will only be shown once. This is a personal token, do not share.<BR>

## Step4: TOWER-CLI CONFIG AND VALIDATION  ----  

#### Check if tower client is installed (both windows and linux)<BR>
tower-cli --version

#### Follow Configuration Steps below <BR>
NOTE- configure under your id, not root<BR>

#### 3a) tower-cli config host https://IP_ADDRESS_ANSIBLE_TOWER:PORT<BR>
EX: tower-cli config host https://ansible-tower.ocp1.sr1.ag1.sp.ibm.local/<BR>

#### 3b) tower-cli config oauth_token TOKENYOUGOTONSTEP3<BR>
EX: tower-cli config oauth_token fsdfMw1M3t9pu9Audfsdk3lpGiQC2

#### 3c) Disable SSL verification<BR>
tower-cli config verify_ssl False<BR>

#### 3e) Add your tower login email id<BR>
tower-cli config username youremailid<BR>
EX: tower-cli config username ankreddy@in.ibm.com

#### 3f) Check configuration<BR>
NOTE-  This command shows your password!<BR>
tower-cli config<BR>

#### 3g) Test ansible tower access<BR>
tower-cli organization list<BR>

### Once you completed above setup, Download "CACF_Inventory_Upload_Template-20.5.xlsx" and follow steps described in INSTRUCTIONS TAB <BR>
