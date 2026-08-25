requires 'perl', 'v5.26';
requires 'CloudStore';
requires 'DBI';
requires 'DBD::Pg';

recommends 'Proc::Daemon';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

