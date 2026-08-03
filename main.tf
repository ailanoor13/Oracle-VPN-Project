terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = "ap-tokyo-1"
}

variable "compartment_id" {
  description = "Root compartment (tenancy) OCID"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

resource "oci_core_vcn" "vpn_vcn" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "vpn-vcn"
}

resource "oci_core_internet_gateway" "vpn_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "vpn-igw"
}

resource "oci_core_route_table" "vpn_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "vpn-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.vpn_igw.id
  }
}

resource "oci_core_security_list" "vpn_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "vpn-security-list"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17"
    udp_options {
      min = 51820
      max = 51820
    }
  }
}

resource "oci_core_subnet" "vpn_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.vpn_vcn.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "vpn-subnet"
  route_table_id    = oci_core_route_table.vpn_route_table.id
  security_list_ids = [oci_core_security_list.vpn_security_list.id]
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

resource "oci_core_instance" "vpn_server" {
  compartment_id      = var.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "vpn-server"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1.ap-tokyo-1.aaaaaaaaoscw5alszu4h62xmlf2d3vusfpyyfxpooqxouff5wyc4w5g7e5bq"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.vpn_subnet.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }
}

output "vpn_server_public_ip" {
  value = oci_core_instance.vpn_server.public_ip
}
