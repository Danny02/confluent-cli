test_zookeeper_should_be_up() {
    assert "kafka status zookeeper | grep UP"
}

test_kafka_should_be_up() {
    assert "kafka status kafka | grep UP"
}

test_connect_should_be_up() {
    assert "kafka status connect | grep UP"
}

test_load_connector() {
    assert "kafka load file-source"
    assert "kafka status file-source | grep RUNNING" "connector should be running"
    assert "kafka unload file-source"
}

test_show_zookeeper_log() {
    assert "kafka log zookeeper" "zookeeper log should exist"
    local fulllog=$(kafka log zookeeper)
    local log=$(echo "$fulllog" | grep -v "no quorum defined")
    assert 'test -n "$log"' "zookeeper log should not be empty" 
    assert_fail 'echo "$log" | egrep "WARN|ERROR"' "zookeeper log should not have errors or warnings" 
}

test_show_kafka_log() {
    assert "kafka log kafka" "kafka log should exist"
    local fulllog=$(kafka log kafka)
    local log=$(echo "$fulllog" | grep -v "No meta.properties file")
    assert 'test -n "$log"' "kafka log should not be empty" 
    assert_fail 'echo "$log" | egrep "WARN|ERROR"' "kafka log should not have errors or warnings" 
}

test_show_connect_log() {
    assert "kafka log connect" "connect log should exist"
    local fulllog=$(kafka log connect)
    local log=$(echo "$fulllog" | grep -i "log4j")
    assert 'test -n "$log"' "connect log should not be empty" 
    assert_fail 'echo "$log" | egrep "WARN|ERROR"' "connect log should not have errors or warnings" 
}

setup_suite() {
    kafka destroy 1>/dev/null
    kafka start
}

teardown_suite() {
    kafka destroy
}