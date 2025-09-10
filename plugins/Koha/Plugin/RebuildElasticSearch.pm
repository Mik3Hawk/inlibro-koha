package Koha::Plugin::Com::Inlibro::RebuildElasticSearch;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use CGI qw(-utf8);
use Try::Tiny;
use Scalar::Util qw(looks_like_number);

use Koha::SearchEngine::Elasticsearch;
use Koha::SearchEngine::Elasticsearch::Indexer;
use Koha::BiblioUtils;                        
use Koha::MetadataRecord::Authority;          

our $VERSION = 2.0;

our $metadata = {
    name            => 'Rebuild Elastic Search',
    author          => 'Noah @inLibro',
    description     => 'Reindexes Elastic Search',
    date_authored   => '2025-09-09',
    date_updated    => '2025-09-09',
    minimum_version => '24.05.00',
    maximum_version => undef,
    version         => $VERSION,
};

# --------------------------- ES utils -----------------------------------

sub _es_client {
    return Koha::SearchEngine::Elasticsearch->new({ index => 'biblios' })->get_elasticsearch;
}

sub _index_names {
    my $es_bib  = Koha::SearchEngine::Elasticsearch->new({ index => 'biblios' });
    my $es_auth = Koha::SearchEngine::Elasticsearch->new({ index => 'authorities' });
    return ($es_bib->index_name, $es_auth->index_name);
}

sub _server_label {
    my $server = '';
    try {
        my $transport = _es_client()->transport;
        my $hosts     = $transport->hosts; # arrayref
        if (ref($hosts) eq 'ARRAY') {
            my @labels = map {
                if (ref($_) eq 'HASH') {
                    my $sch = $_->{scheme} // 'http';
                    my $h   = $_->{host}   // 'localhost';
                    my $p   = $_->{port}   ? ":$_->{port}" : '';
                    "$sch://$h$p";
                } else { "$_" }
            } @$hosts;
            $server = join(',', @labels);
        }
    } catch { $server = '' };
    return $server;
}

sub _count_docs {
# Return the total document count for a given ES index.

# @param    Str $index_name index name
# @returns  Int count (0 on error or missing index name)

    my ($index_name) = @_;

    return 0 unless $index_name;

    my $count = 0;
    try {
        my $es = _es_client();              
        my $r  = $es->count( index => $index_name, body => { query => { match_all => {} } } );
        $count = $r->{count} // 0;
    } catch { $count = 0 };
    return $count;
}

sub _indexes_missing {
#  Check existence of ES indices required by the task (biblios/authorities).

# @param $want_bib: Verify 'biblios' index
# @param $want_auth: Verify 'authorities' index
# @returns ($missing_any, $which_missing): (is a index missing, wich indexes are missing)

    my ($want_bib, $want_auth) = @_;
    my $missing = 0;
    my @which;

    if ($want_bib) {
        my $idx = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'biblios' });
        my $exists = 0;
        eval { $exists = $idx->can('index_exists') ? $idx->index_exists() : 0; 1; } or do { $exists = 0 };
        if (!$exists) { $missing = 1; push @which, 'biblios'; }
    }
    if ($want_auth) {
        my $idx = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'authorities' });
        my $exists = 0;
        eval { $exists = $idx->can('index_exists') ? $idx->index_exists() : 0; 1; } or do { $exists = 0 };
        if (!$exists) { $missing = 1; push @which, 'authorities'; }
    }
    return ($missing, \@which);
}

# ------------------------ Form utils ----------------------

sub _parse_id_list {
    my ($raw) = @_;
    return () unless defined $raw && $raw ne '';
    my @ids = split /[,\s]+/, $raw;
    @ids = grep { defined $_ && $_ =~ /^\d+$/ } @ids;
    return @ids;
}

sub _read_form {
    my ($cgi) = @_;

    my $commit     = $cgi->param('commit');
    $commit = 5000 unless (defined $commit && looks_like_number($commit) && $commit > 0);

    my $delete     = $cgi->param('delete')     ? 1 : 0;
    my $reset      = $cgi->param('reset')      ? 1 : 0;
    my $descending = $cgi->param('descending') ? 1 : 0;
    my $authorities= $cgi->param('authorities')? 1 : 0;
    my $biblios    = $cgi->param('biblios')    ? 1 : 0;

    my @bnumber    = _parse_id_list( scalar $cgi->param('bnumber') );
    my @authid     = _parse_id_list( scalar $cgi->param('authid')  );

    if (!$biblios && !$authorities) { $biblios = 1; $authorities = 1; }

    my $mode = 'update';
    $mode = 'delete' if $delete && !$reset;
    $mode = 'reset'  if $reset;

    return {
        commit       => int($commit),
        mode         => $mode,
        desc         => $descending,
        biblios      => $biblios,
        authorities  => $authorities,
        bnumber      => \@bnumber,
        authid       => \@authid,
    };
}

# ----------------------------- Execution ------------------------------------

sub _prepare_index_if_needed {
# For modes 'delete' and 'reset', (re)create index and optionally update mappings.

# @param $which: specify which index needs to be pepared ; 'biblios'|'authorities'
# @param $cfg: Config from _read_form
# @param $log:

    my ($which, $cfg, $log) = @_;
    return if $cfg->{mode} eq 'update';

    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $which });

    push @$log, "[$which] Drop index…";
    try { $indexer->drop_index() if $indexer->can('index_exists') ? $indexer->index_exists() : 0; } catch { };

    push @$log, "[$which] Create index…";
    try { $indexer->create_index(); } catch { push @$log, "[$which] create_index failed: $_"; };

    if ($cfg->{mode} eq 'reset') {
        push @$log, "[$which] Update mappings…";
        try   { $indexer->update_mappings(); }
        catch { push @$log, "[$which] update_mappings failed: $_"; };
    }
}

# ------------------------ Reindex ---------------------

sub _reindex_biblios {

    my ($cfg, $log) = @_;

    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'biblios' });
    my $batch   = $cfg->{commit} || 5000;

    my (@ids, @recs, $count) = ((), (), 0);

    if (@{ $cfg->{bnumber} }) {
        # Explicit list of biblionumbers
        push @$log, sprintf('[biblios] Reindex %d records (batch=%d)…', scalar(@{ $cfg->{bnumber} }), $batch);
        for my $bn (@{ $cfg->{bnumber} }) {
            my $obj = Koha::BiblioUtils->get_from_biblionumber($bn, item_data => 1);
            my $rec = $obj ? $obj->record : undef;
            next unless $rec;
            push @ids, $bn; push @recs, $rec; $count++;

            if (@ids >= $batch) {
                try { $indexer->update_index(\@ids, \@recs); }
                catch { push @$log, "[biblios] ERROR batch (bn=$ids[0]…): $_"; };
                @ids = (); @recs = ();
            }
        }
    } else {
        # Full scan via Koha iterator (memory-friendly, respects desc)
        my %opt; $opt{desc} = 1 if $cfg->{desc};
        my $it = Koha::BiblioUtils->get_all_biblios_iterator(%opt);

        push @$log, sprintf('[biblios] Reindex all (batch=%d%s)…',
                            $batch, $cfg->{desc} ? ', desc' : '');

        while ( my ($bn, $obj) = $it->next() ) {
            my $rec = $obj ? $obj->record : undef;
            next unless $rec;
            push @ids, $bn; push @recs, $rec; $count++;

            if (@ids >= $batch) {
                try { $indexer->update_index(\@ids, \@recs); }
                catch { push @$log, "[biblios] ERROR batch (bn=$ids[0]…): $_"; };
                @ids = (); @recs = ();
            }
        }
    }

    # Final flush
    if (@ids) {
        try { $indexer->update_index(\@ids, \@recs); }
        catch { push @$log, "[biblios] ERROR final batch (bn=$ids[0]…): $_"; };
    }

    push @$log, "[biblios] Total $count records indexed.";
}

sub _reindex_authorities {

    my ($cfg, $log) = @_;

    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'authorities' });
    my $batch   = $cfg->{commit} || 5000;

    my (@ids, @recs, $count) = ((), (), 0);

    if (@{ $cfg->{authid} }) {
        push @$log, sprintf('[authorities] Reindex %d records (batch=%d)…', scalar(@{ $cfg->{authid} }), $batch);
        for my $aid (@{ $cfg->{authid} }) {
            my $a   = Koha::MetadataRecord::Authority->get_from_authid($aid);
            my $rec = $a ? $a->record : undef;
            next unless $rec;
            push @ids, $aid; push @recs, $rec; $count++;

            if (@ids >= $batch) {
                try { $indexer->index_records(\@ids, undef, undef, \@recs); }
                catch { push @$log, "[authorities] ERROR batch (aid=$ids[0]…): $_"; };
                @ids = (); @recs = ();
            }
        }
    } else {
        my %opt; $opt{desc} = 1 if $cfg->{desc};
        my $it = Koha::MetadataRecord::Authority->get_all_authorities_iterator(%opt);

        push @$log, sprintf('[authorities] Reindex all (batch=%d%s)…',
                            $batch, $cfg->{desc} ? ', desc' : '');

        while ( my ($aid, $a) = $it->next() ) {
            my $rec = $a ? $a->record : undef;
            next unless $rec;
            push @ids, $aid; push @recs, $rec; $count++;

            if (@ids >= $batch) {
                try { $indexer->index_records(\@ids, undef, undef, \@recs); }
                catch { push @$log, "[authorities] ERROR batch (aid=$ids[0]…): $_"; };
                @ids = (); @recs = ();
            }
        }
    }

    if (@ids) {
        try { $indexer->index_records(\@ids, undef, undef, \@recs); }
        catch { push @$log, "[authorities] ERROR final batch (aid=$ids[0]…): $_"; };
    }

    push @$log, "[authorities] Total $count records indexed.";
}

# -------------------------------- Template Util ---------------------------------------

sub _resolve_template {
# Automaticaly choose the right template depending on the koha website lang.
# @param $self: 
# @param $cgi:
# @param $base: Base template name without specification (should always be RebuildElasticSearch for now)
# @return: template name based on the lang.

    my ($self, $cgi, $base) = @_;
    my $locale = $cgi->cookie('KohaOpacLanguage') // '';
    my $template;

    if ($locale) {
        eval { $template = $self->get_template({ file => "${base}_${locale}.tt" }); };

        #FALLBACK => looking for generic lang. template, ex: [fr-CA] becomes only [fr] 
        if (!$template) {
            my $short = substr($locale, 0, 2);
            eval { $template = $self->get_template({ file => "${base}_${short}.tt" }); };
        }
    }

    #DEFAULT => [base].tt (RebuildElasticSearch.tt)
    $template = $self->get_template({ file => "${base}.tt" }) unless $template;
    return $template;
}

# ------------------------------- Plugin ---------------------------------

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub tool {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my ($bib_index, $auth_index) = _index_names();

    my $count_biblios_before     = _count_docs($bib_index);
    my $count_authorities_before = _count_docs($auth_index);

    my $outputs = '';
    my @log;

    if ( uc($cgi->request_method()) eq 'POST' ) {
        my $cfg = _read_form($cgi);

        my ($miss, $which) = _indexes_missing($cfg->{biblios}, $cfg->{authorities});

        if ( $miss && $cfg->{mode} eq 'update' ) {
            push @log,
                "ERREUR: Les index suivants n'existent pas: " . join(', ', @$which),
                "Astuce: cochez 'Supprimer' (delete) ou 'Reset' pour initialiser les index avant l'indexation.";
            $outputs = join("\n", @log);

        } else {
            push @log, sprintf('Strating...: mode=%s; targets=%s; batch=%d; desc=%s',
                            $cfg->{mode},
                            join(',', grep { $cfg->{$_} } qw(biblios authorities)),
                            $cfg->{commit},
                            $cfg->{desc} ? 'oui' : 'non');

            try {
                if ( $cfg->{biblios} ) {
                    _prepare_index_if_needed('biblios', $cfg, \@log);
                    _reindex_biblios($cfg, \@log);
                }
                if ( $cfg->{authorities} ) {
                    _prepare_index_if_needed('authorities', $cfg, \@log);
                    _reindex_authorities($cfg, \@log);
                }
                push @log, 'Done';
            }
            catch {
                chomp $_;
                push @log, "ERROR: $_";
            };

            $outputs = join("\n", @log);
        }
    }

    my $count_biblios_after     = _count_docs($bib_index);
    my $count_authorities_after = _count_docs($auth_index);

    my $server     = _server_label();
    my $index_name = $bib_index;
    $index_name =~ s/_biblios$//;

    my $template = _resolve_template($self, $cgi, 'RebuildElasticSearch');
    $template->param(
        server                    => $server,
        index_name                => $index_name,
        count_authorities         => $count_authorities_before,
        count_biblios             => $count_biblios_before,
        count_authorities_after   => $count_authorities_after,
        count_biblios_after       => $count_biblios_after,
        global_outputs            => $outputs,
    );

    print $cgi->header(-type => 'text/html', -charset => 'utf-8');
    print $template->output();
}

sub uninstall() { return 1; }

1;
