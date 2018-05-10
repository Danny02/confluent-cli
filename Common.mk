PACKAGE_NAME ?= kafka-cli
VERSION ?= 5.0.0-SNAPSHOT
PLATFORM = $(shell uname -s)
INSTALL_FLAGS = -D
ifeq ($(PLATFORM),Linux)
	INSTALL_FLAGS = -D
endif
ifeq ($(PLATFORM),Darwin)
	INSTALL_FLAGS =
endif

.PHONY:

all: build

install: build
ifndef KAFKA_HOME
	$(error Cannot install. KAFKA_HOME is not set)
endif
	install $(INSTALL_FLAGS) -m 755 bin/kafka $(KAFKA_HOME)/bin/kafka

build: oss

prep:
	mkdir -p bin/

oss: prep
	cp -f src/kafka.sh bin/kafka
	chmod 755 bin/kafka

clean:
	rm -rf bin/

distclean: clean

archive:
	git archive --prefix=$(PACKAGE_NAME)-$(VERSION)/ \
		-o $(PACKAGE_NAME)-$(VERSION).tar.gz HEAD
	git archive --prefix=$(PACKAGE_NAME)-$(VERSION)/ \
		-o $(PACKAGE_NAME)-$(VERSION).zip HEAD
