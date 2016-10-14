# encoding: utf-8
# `compliance_report` custom resource to run Chef Compliance profiles and
# send reports to Chef Compliance

include ComplianceHelpers
provides :compliance_report

property :name, String, name_property: true

# to use a chef-compliance server that is used with chef-server integration
property :server, [String, URI, nil]
property :port, Integer
property :insecure, [TrueClass, FalseClass], default: false
property :quiet, [TrueClass, FalseClass], default: true
property :collector, ['chef-visibility', 'chef-compliance', 'chef-server'], default: 'chef-server'

property :environment, String # default: node.environment
property :owner, [String, nil]

default_action :execute

action :execute do
  converge_by "report compliance profiles' results" do
    reports, ownermap = compound_report(profiles)
    blob = node_info
    blob[:reports] = reports
    blob[:profiles] = ownermap

    formatter = collector == 'chef-visibility' ? 'json' : 'json-min'
    # counting total_failed based on the json/json-min format
    if formatter == 'json'
      total_failed = reports.map do |_name, report|
        report['profiles'].map do |profile|
          profile['controls'].map do |control|
            if control['results']
              control['results'].map do |result|
                result['status'] != 'passed' ? 1 : 0
              end
            else
              0
            end
          end
        end
      end.flatten.reduce(:+)
    else
      total_failed = reports.map do |_name, profile|
        if !profile['controls'].empty?
          profile['controls'].map do |control|
            control['status'] != 'passed' ? 1 : 0
          end
        else
          0
        end
      end.flatten.reduce(:+)
    end
    Chef::Log.info "Total number of failed controls: #{total_failed}"

    # resolve owner
    o = return_or_guess_owner

    raise_if_unreachable = run_context.node['audit']['raise_if_unreachable'] if run_context.node['audit']

    case collector
    when 'chef-visibility'
      Collector::ChefVisibility.new(entity_uuid, run_id, blob).send_report
    when 'chef-compliance'
      node.run_state['compliance'] ||= {}
      if node.run_state['compliance']['access_token'] && server
        url = construct_url(server, ::File.join('/owners', o, 'inspec'))
        Collector::ChefCompliance.new(url, blob, node.run_state['compliance']['access_token'], raise_if_unreachable).send_report
      else
        Chef::Log.warn "'server' and 'token' properties required by inspec report collector '#{collector}'. Skipping..."
      end
    when 'chef-server'
      chef_url = server || base_chef_server_url
      if chef_url
        url = construct_url(chef_url + '/compliance/', ::File.join('organizations', o, 'inspec'))
        Collector::ChefServer.new(url, blob).send_report
      else
        Chef::Log.warn "unable to determine chef-server url required by inspec report collector '#{collector}'. Skipping..."
      end
    else
      Chef::Log.warn "#{collector} is not a supported inspec report collector"
    end

    raise "#{total_failed} audits have failed.  Aborting chef-client run." if total_failed > 0 && node['audit']['fail_if_any_audits_failed']
  end
end

# filters resource collection
def profiles
  run_context.resource_collection.select do |r|
    r.is_a?(ComplianceProfile)
  end.flatten
end

def compound_report(*profiles)
  report = {}
  ownermap = {}

  profiles.flatten.each do |prof|
    next unless ::File.exist?(prof.report_path)
    o, p = prof.normalize_owner_profile
    report[p] = ::JSON.parse(::File.read(prof.report_path))
    ownermap[p] = o
  end

  [report, ownermap]
end

def node_info
  n = run_context.node
  {
    node: n.name,
    os: {
      # arch: os[:arch],
      release: n['platform_version'],
      family: n['platform'],
    },
    environment: environment || n.environment,
  }
end

def return_or_guess_owner
  owner || Chef::Config[:chef_server_url].split('/').last
end