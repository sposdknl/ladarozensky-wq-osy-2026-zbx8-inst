IMAGE_NAME = "bento/debian-13"

Vagrant.configure("2") do |config|
    config.ssh.insert_key = false

    config.vm.provider "virtualbox" do |v|
        v.memory = 3072
        v.cpus = 3
    end

    config.vm.define "debian" do |debian|
        debian.vm.box = IMAGE_NAME
        debian.vm.hostname = "mejp-debian13"
        debian.vm.network "forwarded_port", guest: 22, host: 2206, host_ip: "127.0.0.1"
        debian.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1"
    end

config.vm.provision "shell", path: "scripts/install-zabbix.sh"

config.vm.provision "file", source: "Zabbix/export/sposdk.cz_hosts.yaml", destination: "/tmp/sposdk.cz_hosts.yaml"
config.vm.provision "shell", path: "scripts/configure-zabbix.sh"

end