# Enable incoming ssh for a given set of hosts
#
# @summary Enable incoming ssh for a given set of hosts
#   + Opens iptables firewall for the hosts
#   + Configures sshd_config with a Match directive and associated parameter
#     settings
#
# @param users
#   Type: Array
#   Desc: list of users to allow (from hostlist)
#   Note: If both "users" and "groups" are empty, error is raised.
#
# @param groups
#   Type: Array
#   Desc: list of groups to allow (from hostlist)
#   Note: If both "users" and "groups" are empty, error is raised.
#
# @param hostlist
#   Type: Array
#   Desc: list of IPs or Hostnames that (users/groups) are allowed to ssh from
#
# @param sshd_cfg_match_params
#   Type: Hash
#   Desc: sshd config keywords and values
#   Format: sshd_cfg_match_params = { 'keyword1' => 'value1',
#                                     'keyword2' => 'value2',
#                                     'keyword3' => [ 'val3_1','val3_2' ],
#                                   }
#
# @example
#   ssh::allow_from { 'allow incoming ssh by users 1,2,3 from hosts X,Y,Z':
#       'users'                 => Array,
#       'groups'                => Array,
#       'hostlist'              => Array,
#       'sshd_cfg_match_params' => Hash,
#   }
define ssh::allow_from(
    Array[ String, 1 ]   $hostlist,
    Array[ String ]      $users                  = [],
    Array[ String ]      $groups                 = [],
    Hash[ String, Data ] $sshd_cfg_match_params  = {},
) {

    ### CHECK INPUT
    # one of users or groups must not be empty
    if empty( $users ) and empty( $groups ) {
        fail( "'users' and 'groups' cannot both be empty" )
    }


    ### ACCESS.CONF
    ### This sets up the pam access.conf file to allow ssh
    $groups.each |String $group| { $hostlist.each |String $host| {
        pam_access::entry { "Allow ${group} ssh from ${host}":
            group      => $group,
            origin     => $host,
            permission => '+',
            position   => '-1',
        }
    }}
    $users.each |String $user| { $hostlist.each |String $host| {
        pam_access::entry { "Allow ${user} ssh from ${host}":
            user       => $user,
            origin     => $host,
            permission => '+',
            position   => '-1',
        }
    }}


    ### FIREWALL
    $hostlist.each | $host | {
        firewall { "222 allow SSH from ${host} for ${name}":
            dport  => 22,
            proto  => tcp,
            source => $host,
            action => accept,
        }
    }


    ### TCPWRAPPERS
    $hostlist.each | $host | {
        tcpwrappers::allow { "tcpwrappers allow SSH from host '${host}'":
            service => 'sshd',
            address => $host,
        }
    }


    ### SSSD
    # Requires custom fact 'sssd_domains'
    # See: lib/augeasfacter/sssd_info.conf
    # See also: https://github.com/woodsbw/augeasfacter
    ###
    # convert sssd domains from csv string to a puppet array
    $domains = $facts['sssd_domains'].regsubst(/ +/, '', 'G').split(',')
    $domains.each |$domain| {
        if $users =~ Array[String,1] {
            $csv = $users.join(',')
            ::sssd::domain::array_append { "${name} users '${csv}' for sssd domain '${domain}'" :
                domain  => $domain,
                setting => 'simple_allow_users',
                items   => $users,
            }
        }
        if $groups =~ Array[String,1] {
            $csv = $groups.join(',')
            ::sssd::domain::array_append { "${name} groups '${csv}' for sssd domain '${domain}'" :
                domain  => $domain,
                setting => 'simple_allow_groups',
                items   => $groups,
            }
        }
    }

    ### SSHD_CONFIG
    # Defaults
    $config_defaults = {
        'notify' => Service[ sshd ],
    }
    $config_match_defaults = $config_defaults + {
        'position' => 'before first match'
    }

    # Create cfg_match_params for Users and Groups
    $user_params = $users ? {
        Array[ String, 1 ] => { 'AllowUsers' => $users },
        default            => {}
    }
    $group_params = $groups ? {
        Array[ String, 1 ] => { 'AllowGroups' => $groups },
        default            => {}
    }

    # Combine all cfg_match_params into a single hash
    $cfg_match_params = $sshd_cfg_match_params + $user_params + $group_params

    # Hostnames require "Match Host"
    # IPs/CIDRs require "Match Address"
    # Create separate lists and make two separate match blocks in sshd_config
    # criteria will be either "Host" or "Address"
    # pattern will be the CSV string of hostnames or IPs
    # See also: "sshd_config" man page, for details of criteria-pattern pairs
    $name_list = $hostlist.filter | $elem | { $elem =~ /[a-zA-Z]/ }
    $ip_list   = $hostlist.filter | $elem | { $elem !~ /[a-zA-Z]/ }
    #associate the correct criteria with each list, filter empty lists
    $host_data = {
        'Host'    => $name_list,
        'Address' => $ip_list,
    }.filter | $criteria, $list | {
        size( $list ) > 0
    }
    #loop through host_data creating a match block for each criteria-pattern
    $host_data.each | $criteria, $list | {
        $pattern = join( $list, ',' )
        $match_condition = "${criteria} ${pattern}"

        #create match block
        sshd_config_match {
            $match_condition :
            ;
            default: * => $config_match_defaults,
            ;
        }

        #add parameters to the match block
        $cfg_match_params.each | $key, $val | {
            sshd_config {
                "${match_condition} ${key}" :
                    key       => $key,
                    value     => $val,
                    condition => $match_condition,
                ;
                default: * => $config_defaults,
                ;
            }
        }
    }
}
