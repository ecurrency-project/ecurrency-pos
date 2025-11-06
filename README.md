QBitcoin Node Installation
==========================

QBitcoin Node is the core service for running and maintaining the QBitcoin blockchain.
It can be built and deployed using Docker or installed locally via `make`.

## Source code

```bash
git clone https://github.com/qbitcoin-project/qbitcoin.git
cd qbitcoin
```

---

## Installation method 1: Docker image

If you have **Docker** or **Podman** installed, you can build the node container directly from the `qbitcoin` directory:

```bash
make docker
```

> If you prefer to use **Podman**, edit the `Makefile` and replace the word `docker` with `podman`.  
> Make sure you have `make` installed on your system.

An example of a **systemd service** for running the container can be found at:
```
systemd/system/qbitcoin-docker.service
```

Once the service is running inside a Docker container, you can define a convenient alias:

```bash
alias qbitcoin-cli='docker exec qbitcoin qbitcoin-cli'
```

Then you can verify the node is responding:

```bash
qbitcoin-cli help
```

This should print the list of available node commands.

---

## Running and usage

The node uses the following network ports:

- **9666** — peer-to-peer communication between nodes  
- **9667** — management interface for `qbitcoin-cli` (by default bound to `localhost`)

Make sure these ports are open in your firewall if required.

### Basic CLI commands

```bash
qbitcoin-cli help
qbitcoin-cli help <command>
```

Main commands:
| Command | Description |
|----------|-------------|
| `getnewaddress`                                       | Generates a new address and its private key |
| `importkey <private-key>`                             | Imports an existing private key |
| `getaddressbalance <address>`                         | Shows the balance of the specified address |
| `listunspent <address>`                               | Lists unspent outputs (UTXOs) for an address |
| `createrawtransaction <inputs> <outputs>`             | Creates a new transaction |
| `signrawtransactionwithkey <hexstring> <privatekeys>` | Signs a transaction |
| `sendrawtransaction <hexstring>`                      | Broadcasts a signed transaction |

---

## Mining and rewards

After importing your private keys, they are used for block validation  
(if the node runs with `generate=1`, which is the default).  
In this case, the node will participate in block generation and gradually earn rewards —  
you will see your balance increase over time.

---


**QBitcoin Project** — https://github.com/qbitcoin-project



