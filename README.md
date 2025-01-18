eCurrency Node Installation
===========================

eCurrency Node is the core service for running and maintaining the eCurrency blockchain.
It can be built and deployed using Docker or installed locally via `make`.

## Source code

```bash
git clone https://github.com/ecurrency-project/ecurrency-pos.git
cd ecurrency-pos
```

---

## Installation method 1: Docker image

If you have **Docker** or **Podman** installed, pull the prebuilt node image from Docker Hub:

```bash
docker pull ecurrency/ecurrency
```

Alternatively, if you prefer to build the image from source yourself (for example, to verify it or after modifying the code), you can build it directly from the `ecurrency-pos` directory:

```bash
make docker
```

> If you prefer to use **Podman**, edit the `Makefile` and replace the word `docker` with `podman`.
> Make sure you have `make` installed on your system.

The simplest way to run the node is to let Docker itself keep the container running (including across reboots) by starting it with the `--restart=unless-stopped` policy:

```bash
docker run -d --restart=unless-stopped --mount type=bind,source=/etc/qecurrency.conf,target=/etc/qecurrency.conf,readonly --volume /home/qecurrency/database:/database --read-only -p 9666:9666 -p 127.0.0.1:9669:9669 --name qecurrency ecurrency/ecurrency
```

> If you built the image locally with `make docker`, use the image name `qecurrency` instead of `ecurrency/ecurrency`.

The Docker image also provides a **web admin interface** with a blockchain **explorer** and a **wallet** on port **9669**. Run the container with this port published for localhost only (`-p 127.0.0.1:9669:9669`, as in the example above), then open it in your browser:

```
http://127.0.0.1:9669
```

> If you are going to use the wallet, it is recommended to first set a password there, in the same web admin interface.

Alternatively, you can run the container as a **systemd service** — useful if you want logging to a file, running the node under a dedicated user, restart limits, or managing it alongside other system services. An example unit file can be found at:
```
systemd/system/qecurrency-docker.service
```

Once the node is running inside a Docker container, you can define a convenient alias:

```bash
alias qecurrency-cli='docker exec qecurrency qecurrency-cli'
```

Then you can verify the node is responding:

```bash
qecurrency-cli help
```

This should print the list of available node commands.

---

## Running and usage

The node uses the following network ports:

- **9666** — peer-to-peer communication between nodes
- **9667** — management interface for `qecurrency-cli` (by default bound to `localhost`)
- **9668** — for REST API (disabled by default, can be enabled in the configuration file)
- **9669** — web admin interface with explorer and wallet (Docker image only, should be bound to `localhost`)

Make sure these ports are open in your firewall if required.

### Basic CLI commands

```bash
qecurrency-cli help
qecurrency-cli help <command>
```

Main commands:
| Command | Description |
|----------|-------------|
| `getnewaddress`                                       | Generates a new address and its private key |
| `importprivkey <private-key>`                         | Imports an existing private key |
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

**eCurrency Project** — https://github.com/ecurrency-project

---

## License

[Apache-2.0](./LICENSE)
