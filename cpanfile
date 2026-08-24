requires 'perl', 'v5.36';
requires 'CloudStore';
requires 'DBI';
requires 'DBD::Pg';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

