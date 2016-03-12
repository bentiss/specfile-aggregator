specfile-aggregator
===================

A server to update a tito repository based on a specfile repo.

Run with:
---------

    ruby server.rb

The server will generate a secret token and store it in 'token'.

Requirements:
-------------

- git
- git annex
- ruby
- rubygems (with sinatra as a gem)
