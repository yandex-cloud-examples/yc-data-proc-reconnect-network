# Infrastructure for the Yandex Data Processing cluster with DNS for the master host FQDN
#
# RU: https://cloud.yandex.ru/docs/data-proc/tutorials/reconnect-network
# EN: https://cloud.yandex.com/en-ru/docs/data-proc/tutorials/reconnect-network


# Specify the following settings:
locals {
  folder_id              = "" # Your cloud folder ID, same as for provider
  path_to_ssh_public_key = "" # Absolute path to the SSH public key for the Yandex Data Processing cluster
  os_sa_name             = "" # Name of the service account for managing Object Storage bucket and bucket's ACLs
  bucket                 = "" # Name of an Object Storage bucket for input files. Must be unique in the Cloud.

  # Specify these settings ONLY AFTER the cluster is created. Then run "terraform apply" command again
  # You should set up the Yandex Data Processing master node FQDN using the GUI/CLI/API to obtain the FQDN
  dataproc_fqdn = "test" # Substitute "test" with the Yandex Data Processing cluster master node FQDN
}

resource "yandex_vpc_network" "data-proc-network" {
  description = "Network for the Yandex Data Processing cluster"
  name        = "data-proc-network"
}

# NAT gateway and route table configuration
resource "yandex_vpc_gateway" "nat-gateway" {
  name = "test-nat-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "route-table-nat" {
  name       = "route-table-nat"
  network_id = yandex_vpc_network.data-proc-network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat-gateway.id
  }
}

resource "yandex_vpc_subnet" "data-proc-subnet" {
  description    = "Subnet for the Yandex Data Processing cluster"
  name           = "data-proc-subnet"
  network_id     = yandex_vpc_network.data-proc-network.id
  v4_cidr_blocks = ["192.168.1.0/24"]
  zone           = "ru-central1-a"
  route_table_id = yandex_vpc_route_table.route-table-nat.id
}

resource "yandex_vpc_security_group" "data-proc-security-group" {
  description = "Security group for DataProc"
  name        = "data-proc-security-group"
  network_id  = yandex_vpc_network.data-proc-network.id

  egress {
    description    = "Allow outgoing HTTPS traffic"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description       = "Allow any incoming traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description       = "Allow any outgoing traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description    = "Allow access to NTP servers for time syncing"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a service account for Data Processing cluster
resource "yandex_iam_service_account" "dataproc-sa-user" {
  folder_id = local.folder_id
  name      = "data-proc-sa-user"
}

# Grant permissions to the service account
resource "yandex_resourcemanager_folder_iam_member" "dataproc-sa-role-dataproc-agent" {
  folder_id = local.folder_id
  role      = "dataproc.agent"
  member    = "serviceAccount:${yandex_iam_service_account.dataproc-sa-user.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "dataproc-sa-role-dataproc-provisioner" {
  folder_id = local.folder_id
  role      = "dataproc.provisioner"
  member    = "serviceAccount:${yandex_iam_service_account.dataproc-sa-user.id}"
}

# Create a service account for managing Object Storage bucket
resource "yandex_iam_service_account" "obj-storage-sa-user" {
  folder_id = local.folder_id
  name      = local.os_sa_name
}

# Grant storage.admin permission to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-admin" {
  folder_id = local.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.obj-storage-sa-user.id}"
}

# Create an access key for the service account
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  description        = "Static access key for Object Storage"
  service_account_id = yandex_iam_service_account.obj-storage-sa-user.id
}

# Use keys to create a bucket
resource "yandex_storage_bucket" "obj-storage-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = local.bucket

  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa-admin
  ]

  grant {
    id          = yandex_iam_service_account.dataproc-sa-user.id
    type        = "CanonicalUser"
    permissions = ["READ","WRITE"]
  }
}

resource "yandex_dataproc_cluster" "dataproc-cluster" {
  description        = "Yandex Data Processing cluster"
  name               = "dataproc-cluster"
  environment        = "PRODUCTION"
  service_account_id = yandex_iam_service_account.dataproc-sa-user.id
  zone_id            = "ru-central1-a"
  bucket             = local.bucket
  depends_on         = [
    yandex_resourcemanager_folder_iam_member.dataproc-sa-role-dataproc-agent,
    yandex_resourcemanager_folder_iam_member.dataproc-sa-role-dataproc-provisioner
  ]

  security_group_ids = [
    yandex_vpc_security_group.data-proc-security-group.id
  ]

  cluster_config {
    hadoop {
      services = ["HDFS", "YARN", "SPARK", "TEZ", "MAPREDUCE", "HIVE"]
      ssh_public_keys = [
        file(local.path_to_ssh_public_key)
      ]
    }

    subcluster_spec {
      name             = "subcluster-master"
      role             = "MASTERNODE"
      subnet_id        = yandex_vpc_subnet.data-proc-subnet.id
      hosts_count      = 1 # For MASTERNODE only one hosts assigned

      resources {
        resource_preset_id = "s2.micro"    # 4 vCPU Intel Cascade, 16 GB RAM
        disk_type_id       = "network-ssd" # Fast network SSD storage
        disk_size          = 20            # GB
      }
    }

    subcluster_spec {
      name        = "subcluster-data"
      role        = "DATANODE"
      subnet_id   = yandex_vpc_subnet.data-proc-subnet.id
      hosts_count = 1

      resources {
        resource_preset_id = "s2.micro"    # 4 vCPU, 16 GB RAM
        disk_type_id       = "network-ssd" # Fast network SSD storage
        disk_size          = 20            # GB
      }
    }
  }
}

resource "yandex_dns_zone" "data-proc-zone" {
  name             = "dp-private-zone"
  description      = "Yandex Data Processing DNS zone"
  zone             = "data-proc-test-user.org."
  public           = false
  private_networks = [yandex_vpc_network.data-proc-network.id]
}

# DNS record for the Yandex Data Processing cluster master node FQDN
resource "yandex_dns_recordset" "data-proc-record" {
  zone_id = yandex_dns_zone.data-proc-zone.id
  name    = "data-proc-test-user.org."
  type    = "CNAME"
  ttl     = 600
  data    = [local.dataproc_fqdn]
}
