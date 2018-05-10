test_cli_can_run() {
    assert kafka
}

test_create_current_dir() {
    local current=$(kafka current)
    assert 'test -d "$current"'
}

test_destroy_current_dir() {
    local current=$(kafka current)
    teardown
    assert 'test ! -d "$current"'
}

test_has_zookeeper_service() {
    assert "kafka list | grep zookeeper"
}

test_has_kafka_service() {
    assert "kafka list | grep kafka"
}

test_has_connect_service() {
    assert "kafka list | grep connect"
}

test_all_services_down() {
    assert "test $(kafka status | grep DOWN | wc -l) = 3" "all three services should be down"
    assert_fail "kafka status | grep UP" "no service should be up"
}

test_zookeeper_version() {
    local version=$(kafka version zookeeper)
    assert 'test -n "$version"' "should return a version for zookeeper"
}

test_kafka_version() {
    local general_version=$(kafka version)
    local kafka_version=$(kafka version kafka)
    assert 'test -n "$general_version"' "should return kafka's version as default"
    assert 'test -n "$kafka_version"' "should return a version for kafka"
    assert 'test "$general_version" = "$kafka_version"' "default version should equal kafka version"
}

setup_suite() {
    teardown
}

teardown() {
    kafka destroy 1>/dev/null
}