from vyper.interfaces import ERC20

# Voting escrow to have time-weighted votes
# The idea: votes have a weight depending on time, so that users are committed
# to the future of (whatever they are voting for).
# The weight in this implementation is linear until some max time:
# w ^
# 1 +    /-----------------
#   |   /
#   |  /
#   | /
#   |/
# 0 +----+--------------------> time
#       maxtime (2 years?)

struct Point:
    bias: uint256
    slope: uint256  # - dweight / dt * 1e18
    # upper bit in slope is reserved for the sign

struct LockedBalance:
    amount: uint256
    begin: uint256
    end: uint256


WEEK: constant(uint256) = 7 * 86400  # All future times rounded by week
UINT256_SIGN: constant(uint256) = 2 ** 255  # Ugh, I wish there was int256

token: public(address)
supply: public(uint256)

locked: public(map(address, LockedBalance))
locked_history: public(map(address, map(uint256, LockedBalance)))

point_history: public(map(uint256, Point))  # time -> unsigned point
point_changes: public(map(uint256, Point))  # time -> point
last_checkpoint: uint256


@public
def __init__(token_addr: address):
    self.token = token_addr
    self.last_checkpoint = as_unitless_number(block.timestamp)


@private
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):
    old_user_bias: uint256 = 0
    old_user_slope: uint256 = 0
    new_user_bias: uint256 = 0
    new_user_slope: uint256 = 0
    ts: uint256 = as_unitless_number(block.timestamp)
    old_end_change: Point = Point({slope: 0, bias: 0})
    new_end_change: Point = Point({slope: 0, bias: 0})
    if old_locked.amount > 0 and old_locked.end > block.timestamp and old_locked.end > old_locked.begin:
        old_user_slope = 10 ** 18 * old_locked.amount / (old_locked.end - old_locked.begin)
        old_user_bias = old_user_slope * (old_locked.end - ts) / 10 ** 18
    if new_locked.amount > 0 and new_locked.end > block.timestamp and new_locked.end > new_locked.begin:
        new_user_slope = 10 ** 18 * new_locked.amount / (new_locked.end - new_locked.begin)
        new_user_bias = new_user_slope * (new_locked.end - ts) / 10 ** 18

    # Some workaround for not having signed int256...
    old_end_change = self.point_changes[old_locked.end]
    old_bias_sign: bool = (bitwise_and(old_end_change.bias, UINT256_SIGN) > 0)
    old_slope_sign: bool = (bitwise_and(old_end_change.slope, UINT256_SIGN) > 0)
    new_bias_sign: bool = old_bias_sign
    new_slope_sign: bool = old_slope_sign
    if new_locked.end != old_locked.end:
        new_end_change = self.point_changes[new_locked.end]
        new_bias_sign = (bitwise_and(new_end_change.bias, UINT256_SIGN) > 0)
        new_slope_sign = (bitwise_and(new_end_change.slope, UINT256_SIGN) > 0)
    else:
        new_end_change = old_end_change


@public
@nonreentrant('lock')
def deposit(value: uint256, _unlock_time: uint256 = 0):
    # Also used to extent locktimes
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK
    _locked: LockedBalance = self.locked[msg.sender]
    old_supply: uint256 = self.supply

    if unlock_time == 0:
        assert _locked.amount > 0, "No existing stake found"
        assert _locked.end > block.timestamp, "Time to unstake"
        assert value > 0
    else:
        if _locked.amount > 0:
            assert unlock_time >= _locked.end, "Cannot make locktime smaller"
        else:
            assert value > 0
        assert unlock_time > block.timestamp, "Can only lock until time in the future"

    old_locked: LockedBalance = _locked
    if _locked.amount == 0:
        _locked.begin = as_unitless_number(block.timestamp)
    self.supply = old_supply + value
    _locked.amount += value
    if unlock_time > 0:
        _locked.end = unlock_time
    self.locked[msg.sender] = _locked
    self.locked_history[msg.sender][as_unitless_number(block.timestamp)] = _locked

    self._checkpoint(msg.sender, old_locked, _locked)

    if value > 0:
        assert_modifiable(ERC20(self.token).transferFrom(msg.sender, self, value))
    # XXX logs


@public
@nonreentrant('lock')
def withdraw(value: uint256):
    _locked: LockedBalance = self.locked[msg.sender]
    assert block.timestamp >= _locked.end
    old_supply: uint256 = self.supply

    old_locked: LockedBalance = _locked
    _locked.amount -= value
    self.locked[msg.sender] = _locked
    self.locked_history[msg.sender][as_unitless_number(block.timestamp)] = _locked
    self.supply = old_supply - value

    self._checkpoint(msg.sender, old_locked, _locked)

    assert_modifiable(ERC20(self.token).transfer(msg.sender, value))
    # XXX logs


# The following ERC20/minime-compatible methods are not real balanceOf and supply!
# They measure the weights for the purpose of voting, so they don't represent
# real coins.

@public
def balanceOf(addr: address) -> uint256:
    return 0


@public
def balanceOfAt(addr: address, _block: uint256) -> uint256:
    return 0


@public
def totalSupply() -> uint256:
    return 0


@public
def totalSupplyAt(_block: uint256) -> uint256:
    return 0
