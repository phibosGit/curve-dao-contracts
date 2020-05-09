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

struct LockedBalance:
    amount: uint256
    before: uint256


WEEK: constant(uint256) = 7 * 86400  # All future times rounded by week

token: public(address)
supply: public(uint256)

locked: public(map(address, LockedBalance))
locked_history: public(map(address, map(uint256, LockedBalance)))

checkpoints: public(map(uint256, Point))
last_checkpoint: uint256


@public
def __init__(token_addr: address):
    self.token = token_addr


@private
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):
    pass


@public
@nonreentrant('lock')
def deposit(value: uint256, _unlock_time: uint256 = 0):
    # Also used to extent locktimes
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK
    _locked: LockedBalance = self.locked[msg.sender]
    old_supply: uint256 = self.supply

    if unlock_time == 0:
        assert _locked.amount > 0, "No existing stake found"
        assert _locked.before> block.timestamp, "Time to unstake"
    else:
        if _locked.amount > 0:
            assert unlock_time >= _locked.before, "Cannot make locktime smaller"
        assert unlock_time > block.timestamp, "Can only lock until time in the future"

    old_locked: LockedBalance = _locked
    self.supply = old_supply + value
    _locked.amount += value
    if unlock_time > 0:
        _locked.before = unlock_time
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
    assert block.timestamp >= _locked.before
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
