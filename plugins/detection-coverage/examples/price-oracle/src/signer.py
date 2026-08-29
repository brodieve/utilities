"""Fixture: signs published prices. Note that nothing here is logged."""


class Signer:
    def __init__(self, key_id):
        self._key_id = key_id

    def sign(self, payload):
        # No log statement: a use of the signing key leaves no trace anywhere.
        return f"signed:{self._key_id}:{hash(payload)}"
