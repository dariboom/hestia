data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  region_code = { "eu-central-1" = "de", "eu-west-3" = "fr" }[var.region]
  name        = "hestia-${var.environment}-${local.region_code}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
  nat_count   = var.nat_mode == "per_az" ? 3 : 1

  # The isolated tier only talks to its own VPC and, once peered, the other region's VPC.
  isolated_peers = compact([var.vpc_cidr, var.peer_vpc_cidr])
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = local.name })

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "var.region does not match the provider region."
    }
  }
}

# Adopt the default SG and strip every rule so nothing can fall back to it (CIS 5.4).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-default-deny" })
}

# --- Public tier

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = local.name })
}

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${local.name}-public-${local.azs[count.index]}"
    "hestia:tier"            = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.name}-nat-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${local.name}-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

# --- Private tier: egress through NAT

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${local.name}-private-${local.azs[count.index]}"
    "hestia:tier"                     = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = 3
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.nat_mode == "per_az" ? count.index : 0].id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Isolated tier: no internet route; network-peering adds the peer route to this table.

resource "aws_subnet" "isolated" {
  count = 3

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name          = "${local.name}-isolated-${local.azs[count.index]}"
    "hestia:tier" = "isolated"
  })
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-isolated" })
}

resource "aws_route_table_association" "isolated" {
  count          = 3
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

resource "aws_network_acl" "isolated" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.isolated[*].id
  tags       = merge(var.tags, { Name = "${local.name}-isolated" })

  dynamic "ingress" {
    for_each = local.isolated_peers
    content {
      rule_no    = 100 + ingress.key * 10
      action     = "allow"
      protocol   = "-1"
      cidr_block = ingress.value
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = local.isolated_peers
    content {
      rule_no    = 100 + egress.key * 10
      action     = "allow"
      protocol   = "-1"
      cidr_block = egress.value
      from_port  = 0
      to_port    = 0
    }
  }
}
