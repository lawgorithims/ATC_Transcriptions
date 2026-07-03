PREFIX ?= /opt/commsight

.PHONY: help run devices test unittest install uninstall syntax

help:
	@echo "make run        - run the server locally in the foreground"
	@echo "make devices    - list ALSA capture devices + the auto pick"
	@echo "make test       - record a 5s sample with a level meter"
	@echo "make unittest   - run the server + LED-meter test suites (no hardware needed)"
	@echo "make install    - sudo install + enable the systemd service"
	@echo "make uninstall  - sudo remove the service + code"
	@echo "make syntax     - byte-compile the Python (sanity check)"

run:
	python3 -m commsight_cockpit_audio

devices:
	python3 -m commsight_cockpit_audio --list-devices

test:
	./bin/record-test

unittest:
	python3 -m unittest discover -s test -p "test_*.py" -v

install:
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

syntax:
	python3 -m py_compile commsight_cockpit_audio/*.py
	@echo "OK"
