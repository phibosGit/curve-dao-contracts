# The contract which controls gauges and issuance of coins through those

contract CRV20:
    def start_epoch_time_write() -> timestamp: modifying


YEAR: constant(uint256) = 86400 * 365
RATE_REDUCTION_TIME: constant(uint256) = YEAR


admin: address  # Can and will be a smart contract
token: address  # CRV token

# Gauge parameters
# All numbers are "fixed point" on the basis of 1e18
n_gauge_types: public(int128)
n_gauges: public(int128)

gauges: public(map(int128, address))
gauge_types: public(map(address, int128))
gauge_weights: public(map(address, uint256))

n_nonzero_gauges: public(int128)
n_nonupdated_gauges: public(int128)
gauges_last_checkpoint: public(map(address, timestamp))

type_weights: public(map(int128, uint256))
weight_sums_per_type: public(map(int128, uint256))
total_weight: public(uint256)

last_change: public(timestamp)  # Not including change of epoch if any


@public
def __init__(token_address: address):
    self.admin = msg.sender
    self.token = token_address
    self.n_gauge_types = 0
    self.n_gauges = 0
    self.n_nonzero_gauges = 0
    self.total_weight = 0
    self.last_change = block.timestamp


@public
def transfer_ownership(addr: address):
    assert msg.sender == self.admin
    self.admin = addr


@public
def add_type():
    assert msg.sender == self.admin
    n: int128 = self.n_gauge_types
    self.n_gauge_types = n + 1
    # maps contain 0 values by default, no need to do anything
    # zero weights don't change other weights - no need to change last_change


@public
def add_gauge(addr: address, gauge_type: int128, weight: uint256 = 0):
    assert msg.sender == self.admin
    assert (gauge_type >= 0) and (gauge_type < self.n_gauge_types)
    assert self.n_nonupdated_gauges <= 0  # Cannot be <0 but...
    # If someone adds the same gauge twice, it will override the previous one
    # That's probably ok

    n: int128 = self.n_gauges
    self.n_gauges += 1

    self.gauges[n] = addr
    self.gauge_types[addr] = gauge_type
    self.gauge_weights[addr] = weight

    if weight > 0:
        # Same timestamp change == vulnerability
        assert self.last_change != block.timestamp
        self.last_change = block.timestamp
        self.gauges_last_checkpoint[addr] = block.timestamp
        self.n_nonupdated_gauges = self.n_nonzero_gauges
        self.n_nonzero_gauges += 1
        self.weight_sums_per_type[gauge_type] += weight
        self.total_weight += self.type_weights[gauge_type] * weight


@public
@constant
def gauge_relative_weight(addr: address) -> uint256:
    _total_weight: uint256 = self.total_weight
    if _total_weight > 0:
        return 10 ** 18 * self.type_weights[self.gauge_types[addr]] * self.gauge_weights[addr] / self.total_weight
    else:
        return 0


@public
def change_type_weight(type_id: int128, weight: uint256):
    assert msg.sender == self.admin
    assert self.n_nonupdated_gauges <= 0  # Cannot be <0 but...

    old_weight: uint256 = self.type_weights[type_id]
    old_total_weight: uint256 = self.total_weight
    _weight_sums_per_type: uint256 = self.weight_sums_per_type[type_id]

    self.total_weight = old_total_weight + _weight_sums_per_type * weight - _weight_sums_per_type * old_weight
    self.type_weights[type_id] = weight

    self.n_nonupdated_gauges = self.n_nonzero_gauges

    # Same timestamp change == vulnerability
    assert self.last_change != block.timestamp
    self.last_change = block.timestamp


@public
def change_gauge_weight(addr: address, weight: uint256):
    assert msg.sender == self.admin
    assert self.n_nonupdated_gauges <= 0  # Cannot be <0 but...

    gauge_type: int128 = self.gauge_types[addr]
    type_weight: uint256 = self.type_weights[gauge_type]
    old_weight_sums: uint256 = self.weight_sums_per_type[gauge_type]
    old_total_weight: uint256 = self.total_weight
    old_weight: uint256 = self.gauge_weights[addr]

    if (weight == 0) and (old_weight > 0):
        self.n_nonzero_gauges -= 1

    weight_sums: uint256 = old_weight_sums + weight - old_weight
    self.gauge_weights[addr] = weight
    self.weight_sums_per_type[gauge_type] = weight_sums
    self.total_weight = old_total_weight + weight_sums * type_weight - old_weight_sums * type_weight

    self.n_nonupdated_gauges = self.n_nonzero_gauges - 1
    self.gauges_last_checkpoint[addr] = block.timestamp
    # Same timestamp change == vulnerability
    assert self.last_change != block.timestamp
    self.last_change = block.timestamp


@private
def _checkpoint_gauge(addr: address):
    # Everyone can and encouraged to do it
    checkpoint: timestamp = self.gauges_last_checkpoint[addr]
    _last_change: timestamp = self.last_change
    if checkpoint != _last_change:
        self.gauges_last_checkpoint[addr] = _last_change
        if self.gauge_weights[addr] > 0:
            self.n_nonupdated_gauges -= 1
            # Still ok to checkpoint if zero
        # XXX call something to _actually_ checkpoint it in the gauge


@public
def checkpoint_gauge(addr: address):
    self._checkpoint_gauge(addr)


@public
def checkpoint_all_gauges():
    # Will work only until certain number of pools * gauges
    # After that's too much - checkpoint_gauge() can be used
    _n_gauges: int128 = self.n_gauges
    for i in range(1000):
        addr: address = self.gauges[i]
        if self.gauge_weights[addr] > 0:
            self._checkpoint_gauge(addr)
        if i >= _n_gauges:
            break
