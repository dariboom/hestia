package hestia.network_test

import data.hestia.network
import rego.v1

hcl_module(path, body) := [{"path": path, "contents": {"module": {"network": [body]}}}]

test_prod_single_nat_denied if {
	count(network.deny) == 1 with input as hcl_module("live/prod/de/main.tf", {"nat_mode": "single"})
}

test_prod_per_az_allowed if {
	count(network.deny) == 0 with input as hcl_module("live/prod/de/main.tf", {"nat_mode": "per_az"})
}

test_prod_default_allowed if {
	count(network.deny) == 0 with input as hcl_module("live/prod/fr/main.tf", {"source": "../../../modules/network"})
}

test_dev_single_nat_allowed if {
	count(network.deny) == 0 with input as hcl_module("live/dev/de/main.tf", {"nat_mode": "single"})
}
