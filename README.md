specfile-aggregator
===================

A server to update a tito repository based on a specfile repo.

Run with:
---------

    export SECRET_TOKEN='xxxxxxxxxxxxxxxxxxx'
    ruby server.rb

To generate a secret token:
---------------------------

ruby -rsecurerandom -e 'puts SecureRandom.hex(20)
