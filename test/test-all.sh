test_cli_can_run() {
    confluent
    assert confluent
}

test_show_status() {
    confluent status
    assert confluent status
}

test_start_kafka() {
    confluent start
    assert confluent start
}