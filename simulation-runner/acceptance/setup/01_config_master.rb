require 'set'
require 'json'

module Puppet
module Gatling
module LoadTest
  class ScenarioConfig

    Module = Struct.new(:name, :version)
    Node = Struct.new(:name, :classes)

    def initialize(modules, classes, nodes)
      @modules = modules
      @classes = classes
      @nodes = nodes
    end

    attr_accessor :modules, :classes, :nodes

    def self.parse(scenario_config_path)
      scenario = JSON.parse(File.read(scenario_config_path))
      modules = Set.new
      classes = Set.new
      nodes = []

      scenario["nodes"].each do |node|
        node_config_path = File.join(File.dirname(File.expand_path(scenario_config_path)),
                                "..", "nodes", node["node_config"])
        node_config = JSON.parse(File.read(node_config_path))
        node_config["modules"].each do |m|
          modules.add(Module.new(m["name"], m["version"]))
        end
        node_config["classes"].each do |c|
          classes.add(c)
        end
        nodes.push(Node.new(node_config["certname"], node_config["classes"]))
      end

      ScenarioConfig.new(modules.to_a, classes.to_a, nodes)

    end
  end
end
end
end


rake_cmd='RAILS_ENV=production /opt/puppet/bin/rake -f /opt/puppet/share/puppet-dashboard/Rakefile'
test_name = "Setup for Gatling Performance Run"

authconf = %q{path /
auth any
allow *
}

# create custom auth.conf
on master, "mv /etc/puppetlabs/puppet/auth.conf /etc/puppetlabs/puppet/auth.conf.bak"
create_remote_file(master, '/etc/puppetlabs/puppet/auth.conf', authconf)
on master, "chown root:pe-puppet /etc/puppetlabs/puppet/auth.conf && chmod 640 /etc/puppetlabs/puppet/auth.conf"

config = Puppet::Gatling::LoadTest::ScenarioConfig.parse(File.expand_path(File.join("../simulation-runner", ENV['PUPPET_GATLING_SIMULATION_CONFIG'])))

# Install modules and class per node
config.modules.each do |m|
  on master, "puppet module install #{m.name} -v #{m.version} --force"
end

result = on master, "#{rake_cmd} nodeclass:list"
class_list = result.stdout.split

# register nodes and classes
config.classes.select {|c| ! (class_list.include?(c)) }.each do |c|
  on master, "#{rake_cmd} nodeclass:add name=#{c}"
end

result = on master, "#{rake_cmd} node:list"
node_list = result.stdout.split

# Add nodenames
config.nodes.each do |n|
  step "Configuring node '#{n.name}'" do
    unless node_list.include?(n.name)
      on master, "#{rake_cmd} node:add name=#{n.name}"
    end

    # First we reset the list of classes for the node to the default PE classes.
    # NOTE: eventually we probably need to move this list of initial classes
    # to a config file, because this assumes we'll only ever be doing testing
    # against PE.  (Although all of this stuff assumes we have at least the
    # dashboard and rake tasks.)
    on master, "#{rake_cmd} node:classes name=#{n.name} classes=pe_compliance,pe_accounts,pe_mcollective"
    n.classes.each do |c|
      on master, "#{rake_cmd} node:addclass name=#{n.name} class=#{c}"
    end

    # Here we'll just print out the final list of classes for the node so that
    # it's visible in the log.
    on master, "#{rake_cmd} node:listclasses name=#{n.name}"
  end

end
