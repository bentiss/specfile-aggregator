specfile-aggregator
===================

A server to update a tito repository based on a specfile repo.

Run with:
---------

    ruby server.rb

The server will generate a secret token and store it in 'token'.

Requirements:
-------------

- tito
- copr-cli
- git
- ruby
- rubygems (with sinatra as a gem)

You also need to set up your copr-cli token in ~/.config/copr, see
https://copr.fedorainfracloud.org/api/
