# Inter-region VPC peering DE (requester) <-> FR (accepter), same account (ADR-006).

data "aws_region" "de" {
  provider = aws.de
}

data "aws_region" "fr" {
  provider = aws.fr
}

# Read every target route table so routes can refuse public ones (any IGW route) and foreign VPCs.
data "aws_route_table" "de" {
  provider = aws.de
  count    = length(var.de_route_table_ids)

  route_table_id = var.de_route_table_ids[count.index]
}

data "aws_route_table" "fr" {
  provider = aws.fr
  count    = length(var.fr_route_table_ids)

  route_table_id = var.fr_route_table_ids[count.index]
}

locals {
  name = "hestia-${var.environment}-de-fr"

  de_rules = { for p in setproduct(var.de_ingress_security_group_ids, var.allowed_ports) : "${p[0]}:${p[1]}" => p }
  fr_rules = { for p in setproduct(var.fr_ingress_security_group_ids, var.allowed_ports) : "${p[0]}:${p[1]}" => p }
}

resource "aws_vpc_peering_connection" "this" {
  provider = aws.de

  vpc_id      = var.de_vpc_id
  peer_vpc_id = var.fr_vpc_id
  peer_region = data.aws_region.fr.region
  tags        = merge(var.tags, { Name = local.name, Side = "requester" })

  lifecycle {
    precondition {
      condition     = data.aws_region.de.region == "eu-central-1" && data.aws_region.fr.region == "eu-west-3"
      error_message = "Provider aws.de must be eu-central-1 and aws.fr must be eu-west-3."
    }
  }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.fr

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true
  tags                      = merge(var.tags, { Name = local.name, Side = "accepter" })
}

# DNS options can only be set once the connection is active, from each side's own region.
resource "aws_vpc_peering_connection_options" "requester" {
  provider = aws.de

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider = aws.fr

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "de_to_fr" {
  provider = aws.de
  count    = length(var.de_route_table_ids)

  route_table_id            = var.de_route_table_ids[count.index]
  destination_cidr_block    = var.fr_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  lifecycle {
    precondition {
      condition     = data.aws_route_table.de[count.index].vpc_id == var.de_vpc_id
      error_message = "DE route table ${var.de_route_table_ids[count.index]} is not in de_vpc_id."
    }

    precondition {
      condition     = !anytrue([for r in data.aws_route_table.de[count.index].routes : try(startswith(r.gateway_id, "igw-"), false)])
      error_message = "DE route table ${var.de_route_table_ids[count.index]} routes to an internet gateway; peering routes go on private/isolated tables only."
    }
  }
}

resource "aws_route" "fr_to_de" {
  provider = aws.fr
  count    = length(var.fr_route_table_ids)

  route_table_id            = var.fr_route_table_ids[count.index]
  destination_cidr_block    = var.de_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  lifecycle {
    precondition {
      condition     = data.aws_route_table.fr[count.index].vpc_id == var.fr_vpc_id
      error_message = "FR route table ${var.fr_route_table_ids[count.index]} is not in fr_vpc_id."
    }

    precondition {
      condition     = !anytrue([for r in data.aws_route_table.fr[count.index].routes : try(startswith(r.gateway_id, "igw-"), false)])
      error_message = "FR route table ${var.fr_route_table_ids[count.index]} routes to an internet gateway; peering routes go on private/isolated tables only."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "de_from_fr" {
  provider = aws.de
  for_each = local.de_rules

  security_group_id = each.value[0]
  description       = "TCP ${each.value[1]} from FR VPC via peering"
  cidr_ipv4         = var.fr_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
  tags              = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "fr_from_de" {
  provider = aws.fr
  for_each = local.fr_rules

  security_group_id = each.value[0]
  description       = "TCP ${each.value[1]} from DE VPC via peering"
  cidr_ipv4         = var.de_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
  tags              = var.tags
}
