test_start_required_services() {
    kafka start kafka 1>/dev/null
    assert "kafka status zookeeper | grep UP" "zookeeper should be up"
}

test_stop_depending_services() {
    kafka start kafka 1>/dev/null
    kafka stop zookeeper 1>/dev/null
    assert "kafka status kafka | grep DOWN" "kafka should be down"
}

setup_suite() {
    teardown
}

teardown() {
    kafka destroy 1>/dev/null
}