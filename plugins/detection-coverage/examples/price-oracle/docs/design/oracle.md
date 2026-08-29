# Price oracle design

## Overview

A scheduled poller reads spot prices for configured trading pairs from several public
exchange APIs every five minutes, signs the result, and publishes it for downstream
consumers.

## Data sources

Public REST price endpoints on each configured exchange. No authentication; no SLA.

## Assumptions

- We assume the exchange APIs return honest, current prices.
- We assume the publish topic is only writable by this service.
- We assume clock skew across pollers is under one second.

## Signing

Published prices are signed with a KMS key. Only the poller's execution role should be able
to use it.

## Non-goals

We do not defend against a compromised exchange colluding with a downstream consumer.
