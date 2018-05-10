# Kafka CLI
A CLI to start and manage Kafka from command line.

## Status

|Shell|Status|
|-|-|
|MSYS2|[![mysys][]][build-link]|
|Cygwin|[![cygwin][]][build-link]|

[mysys]: https://appveyor-matrix-badges.herokuapp.com/repos/Danny02/kafka-cli-oylt8/branch/master/1
[cygwin]: https://appveyor-matrix-badges.herokuapp.com/repos/Danny02/kafka-cli-oylt8/branch/master/2
[build-link]: https://ci.appveyor.com/project/Danny02/kafka-cli-oylt8

## Installation

* Download and install [Kafka](https://kafka.apache.org/downloads)

* Checkout *kafka-cli* by running:

    ```bash
    $ git clone git@github.com:Danny02/kafka-cli.git
    ```

* Set *KAFKA_HOME* environment variable to point to the location of Kafka. For instance:

    ```bash
    $ export KAFKA_HOME=/usr/local/kafka_2.11-1.1.0
    ```

* Install *kafka-cli*:

    ```bash
    $ cd kafka-cli; make install
    ```

## Usage
To get a list of available commands, run:

```bash
$ export PATH=${KAFKA_HOME}/bin:${PATH};
$ kafka help
```

Examples:

* Start all the services!
```bash
$ kafka start
```

* Retrieve their status:
```bash
$ kafka status
```

* Open the log file of a service:
```bash
$ kafka log connect
```

* Access runtime stats of a service:
```bash
$ kafka top kafka
```

* Discover the availabe Connect plugins:
```bash
$ kafka list plugins
```

* or list the predefined connector names:
```bash
$ kafka list connectors
```

* Load a couple connectors:
```bash
$ kafka load file-source
$ kafka load file-sink
```

* Get a list with the currently loaded connectors:
```bash
$ kafka status connectors
```

* Check the status of a loaded connector:
```bash
$ kafka status file-source
```

* Read the configuration of a connector:
```bash
$ kafka config file-source
```

* Reconfigure a connector:
```bash
$ kafka config file-source -d ./updated-file-source-config.json
```

* or reconfigure using a properties file:
```bash
$ kafka config file-source -d ./updated-file-source-config.properties
```

* Figure out where the data and the logs of the current kafka run are stored:
```bash
$ kafka current
```

* Unload a specific connector:
```bash
$ kafka unload file-sink
```

* Stop the services:
```bash
$ kafka stop
```

* Start on a clean slate next time (deletes data and logs of a kafka run):
```bash
$ kafka destroy
```

Set KAFKA_CURRENT if you want to use a top directory for kafka runs other than your platform's tmp directory.

```bash
$ cd $KAFKA_HOME
$ mkdir -p var
$ export KAFKA_CURRENT=${KAFKA_HOME}/var
$ kafka current
```
