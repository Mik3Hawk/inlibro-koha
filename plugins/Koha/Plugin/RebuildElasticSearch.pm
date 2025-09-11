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

our $VERSION = 2.2;

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

sub _es {
    my ($which) = @_;
    $which ||= 'biblios';
    return Koha::SearchEngine::Elasticsearch->new({ index => $which });
}

sub _index_names {
    my $bib = _es('biblios')->index_name;
    my $auth = _es('authorities')->index_name;
    return ($bib, $auth);
}

sub _server_label {
    my $params = _es('biblios')->get_elasticsearch_params; # { nodes => [...] , index_name => ... }
    my $nodes = $params->{nodes} // [];
    return join(',', @$nodes);
}

# Return the total document count for a given ES index.

# @param $index_name
# @return (Int) the number of total document count
sub _count_docs {
    my ($index_name) = @_;
    return 0 unless $index_name;

    # Déduire le type Koha pour choisir le bon client (biblios/authorities)
    my $which = ($index_name =~ /authorit/i) ? 'authorities' : 'biblios';

    # 1) Court-circuit si l’index n’existe pas
    my $exists = 0;
    eval {
        my $idx = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $which });
        $exists = $idx->can('index_exists') ? $idx->index_exists() : 1;
        1;
    } or do {$exists = 0;};
    return 0 unless $exists;

    my $count = 0;
    try {
        my $es = _es($which)->get_elasticsearch;;
        my $r = $es->count(
            index              => $index_name,
            q                  => '*:*',
            allow_no_indices   => 1,
            ignore_unavailable => 1,
            expand_wildcards   => 'open,hidden',
        );
        $count = $r->{count} // 0;
    }
    catch {
        try {
            my $es = _es($which)->get_elasticsearch;;
            my $r = $es->search(
                index              => $index_name,
                body               => {
                    query            => { match_all => {} },
                    size             => 0,
                    track_total_hits => \1,
                },
                allow_no_indices   => 1,
                ignore_unavailable => 1,
                expand_wildcards   => 'open,hidden',
            );
            $count = $r->{hits}{total}{value} // 0;
        }
        catch {$count = 0};
    };
    return $count;
}

#  Check existence of ES indices required by the task (biblios/authorities).

# @param $want_bib: Verify 'biblios' index
# @param $want_auth: Verify 'authorities' index
# @returns ($missing_any, $which_missing): (is a index missing, wich indexes are missing)
sub _indexes_missing {

    my ($want_bib, $want_auth) = @_;
    my $missing = 0;
    my @which;

    if ($want_bib) {
        my $idx = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'biblios' });
        my $exists = 0;
        eval {
            $exists = $idx->can('index_exists') ? $idx->index_exists() : 0;
            1;
        } or do {$exists = 0};
        if (!$exists) {
            $missing = 1;
            push @which, 'biblios';
        }
    }
    if ($want_auth) {
        my $idx = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'authorities' });
        my $exists = 0;
        eval {
            $exists = $idx->can('index_exists') ? $idx->index_exists() : 0;
            1;
        } or do {$exists = 0};
        if (!$exists) {
            $missing = 1;
            push @which, 'authorities';
        }
    }
    return ($missing, \@which);
}

# ------------------------ Form utils ----------------------

sub _read_form {
    my ($cgi) = @_;

    my $commit = $cgi->param('commit');
    $commit = 5000 unless (defined $commit && looks_like_number($commit) && $commit > 0);

    my $delete = $cgi->param('delete') ? 1 : 0;
    my $reset = $cgi->param('reset') ? 1 : 0;
    my $descending = $cgi->param('descending') ? 1 : 0;
    my $authorities = $cgi->param('authorities') ? 1 : 0;
    my $biblios = $cgi->param('biblios') ? 1 : 0;

    my $bnumber = scalar $cgi->param('bnumber') // undef;

    $bnumber = (defined $bnumber && $bnumber ne '') ? int($bnumber) : undef;

    my $authid = scalar $cgi->param('authid') // undef;
    $authid = (defined $authid && $authid ne '') ? int($authid) : undef;

    # Si aucune cible cochée, on prend les deux
    if (!$biblios && !$authorities) {
        $biblios = 1;
        $authorities = 1;
    }

    my $mode = 'update';
    $mode = 'delete' if $delete && !$reset;
    $mode = 'reset' if $reset;

    return {
        commit      => int($commit),
        mode        => $mode,
        desc        => $descending,
        biblios     => $biblios,
        authorities => $authorities,
        bnumber     => $bnumber,
        authid      => $authid,
    };
}

# ----------------------------- Execution ------------------------------------

# For modes 'delete' and 'reset', (re)create index and optionally update mappings.

# @param $which: specify which index needs to be pepared ; 'biblios'|'authorities'
# @param $cfg: Config from _read_form
# @param $log:
sub _prepare_index_if_needed {

    my ($which, $cfg, $log) = @_;
    return if $cfg->{mode} eq 'update';

    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $which });

    push @$log, "[$which] Drop index…";
    try {$indexer->drop_index() if $indexer->can('index_exists') ? $indexer->index_exists() : 0;}
    catch {};

    push @$log, "[$which] Create index…";
    try {$indexer->create_index();}
    catch {push @$log, "[$which] create_index failed: $_";};

    if ($cfg->{mode} eq 'reset') {
        push @$log, "[$which] Update mappings…";
        try {$indexer->update_mappings();}
        catch {push @$log, "[$which] update_mappings failed: $_";};
    }
}

# ----------------------------------- Reindex Biblios --------------------------------

# Try to reindex a single biblionumber immediately (no batching)
#
# @param $bn   biblionumber
# @param $log  arrayref (log collector)
# @return 1 if indexed, 0 if skipped
sub _reindex_biblio {
    my ($bn, $log) = @_;
    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'biblios' });

    my $obj = eval {Koha::BiblioUtils->get_from_biblionumber($bn, item_data => 1)};
    unless (defined $obj) {
        push @$log, "[biblios] WARNING: No biblio record for biblionumber=$bn --> Skipped.";
        return 0;
    }

    my $rec = eval {$obj->record};
    unless (defined $rec) {
        push @$log, "[biblios] WARNING: No MARC record for biblionumber=$bn --> Skipped.";
        return 0;
    }

    try {
        $indexer->update_index([ $bn ], [ $rec ]);
        push @$log, "[biblios] SUCCESS: Biblio #$bn was successfully reindexed.";
        return 1;
    }
    catch {
        push @$log, "[biblios] ERROR: Unable to update index for biblionumber=$bn --> Skipped.";
        return 0;
    };
}

# Reindex all biblios using an iterator and batch flush
#
# @param $cfg  hash  { commit => N, desc => bool }
# @param $log  array
# @return void
sub _reindex_biblios {
    my ($cfg, $log) = @_;
    my $batch = $cfg->{commit} || 5000;

    my @ids;
    my @recs;
    my $count = 0;
    push @$log, "[debug] created; size now " . scalar(@ids);

    my %opt;
    $opt{desc} = 1 if $cfg->{desc};

    my $it = Koha::BiblioUtils->get_all_biblios_iterator(%opt);

    push @$log, sprintf('[biblios] INFO: Reindex all (batch=%d%s)...', $batch, $cfg->{desc} ? ', desc' : '');

    while (my $obj = $it->next) {
        my $bn = eval {$obj->id} // "?";
        my $rec = eval {$obj->record};

        unless (defined $bn && $bn =~ /^\d+$/ && $bn > 0) {
            push @$log, "[biblios] WARNING: Missing / Invalid biblionumber --> Skipped.";
            next;
        }
        unless (defined $rec) {
            push @$log, "[biblios] WARNING: No MARC record for biblionumber=$bn --> Skipped.";
            next;
        }

        push(@ids, $bn);
        push(@recs, $rec);

        if (@ids >= $batch) {
            $count += _flush_batch('biblios', 'biblios', \@ids, \@recs, $log);
        }
    }

    # Flusing remaining objects in the flusher
    if (@ids) {
        $count += _flush_batch('biblios', 'biblios', \@ids, \@recs, $log);
    }
    push @$log, "[biblios] INFO: Total of " . ($count // 0) . " records were indexed.";
}

# ----------------------------------------- Reindex Authorities -----------------------------

# Reindex a single authority immediately (no batching)
#
# @param $aid  authid
# @param $log  arrayref (log collector)
# @return 1 if indexed, 0 if skipped
sub _reindex_authority {
    my ($aid, $log) = @_;
    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => 'authorities' });

    my $auth = eval {Koha::MetadataRecord::Authority->get_from_authid($aid)};
    unless (defined $auth) {
        push @$log, "[authorities] WARNING: No authority object for authid=$aid --> Skipped.";
        return 0;
    }

    my $rec = eval {$auth->record};
    unless (defined $rec) {
        push @$log, "[authorities] WARNING: No MARC record for authid=$aid --> Skipped.";
        return 0;
    }

    try {
        $indexer->update_index([ $aid ], [ $rec ]);
        push @$log, "[authorities] SUCCESS: Authority #$aid was successfully reindexed.";
        return 1;
    }
    catch {
        push @$log, "[authorities] ERROR: Unable to update index for authid=$aid --> Skipped.";
        return 0;
    };
}

# Reindex authorities (either a provided list, or all via iterator) with the same batching principle as biblios
#
# @param $cfg  hashref  { commit => N, desc => bool, authid => [ ... ] }
# @param $log  arrayref
# @return void
sub _reindex_authorities {
    my ($cfg, $log) = @_;
    my $batch = $cfg->{commit} || 5000;

    my @ids;
    my @recs;
    my $count = 0;

    my %opt;
    $opt{desc} = 1 if $cfg->{desc};

    my $it = Koha::MetadataRecord::Authority->get_all_authorities_iterator(%opt);

    push @$log, sprintf('[authorities] INFO: Reindex all (batch=%d%s)...', $batch, $cfg->{desc} ? ', desc' : '');

    while (my $auth = $it->next) {
        my $aid = eval {$auth->authid} // '?';
        my $rec = eval {$auth->record};

        unless (defined $aid && $aid =~ /^\d+$/ && $aid > 0) {
            push @$log, "[authorities] WARNING: Missing / Invalid auth --> Skipped.";
            next;
        }
        unless (defined $rec) {
            push @$log, "[authorities] WARNING: No MARC record for auth=$aid --> Skipped.";
            next;
        }

        push @ids, $aid;
        push @recs, $rec;

        if (@ids >= $batch) {
            $count += _flush_batch('authorities', 'authorities', \@ids, \@recs, $log);
        }
    }
    # Flusing remaining objects in the flusher
    if (@ids) {
        $count += _flush_batch('authorities', 'authorities', \@ids, \@recs, $log);
    }

    push @$log, "[authorities] INFO: Total of " . ($count // 0) . " authorities were indexed.";
}
# ----------------------------------- Flusher -----------------------------------------

# Flush a batch to Elasticsearch and clear buffers
#
# @param $index  string   Elasticsearch index name ('biblios' | 'authorities')
# @param $label  string   Label for logs ('biblios' | 'authorities')
# @param $ids    arrayref Buffer of ids
# @param $recs   arrayref Buffer of MARC::Record objects (same order as $ids)
# @param $log    arrayref Log collector
# @returns the number of indexed things
sub _flush_batch {
    my ($index, $label, $ids, $recs, $log) = @_;
    return 0 unless @$ids; #nothing to flush

    my $n = 0;

    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $index });

    try {
        $indexer->update_index(\@$ids, \@$recs);
        $n = scalar(@$ids);
        push @$log, sprintf("[%s] INFO: Indexed batch (%d records, first id=%s)",
            $label, $n, @$ids[0]);

    }
    catch {
        push @$log, sprintf("[%s] ERROR: batch (first id=%s) --> %s",
            $label, @$ids[0], $_);
    };

    # Réinitialisation des buffers
    @$ids = ();
    @$recs = ();
    return $n;
}
# -------------------------------- Template Util ---------------------------------------

# Automatically choose the right template depending on the koha website lang.
# @param $self:
# @param $cgi:
# @param $base: Base template name without specification (should always be RebuildElasticSearch for now)
# @return: the template object
sub _resolve_template {

    my ($self, $cgi, $base) = @_;
    my $locale = $cgi->cookie('KohaOpacLanguage') // '';
    my $template;

    if (defined $locale) {
        eval {$template = $self->get_template({ file => "${base}_${locale}.tt" });};

        #FALLBACK => looking for generic lang. template, ex: [fr-CA] becomes only [fr] 
        if (!defined $template) {
            my $short = substr($locale, 0, 2);
            eval {$template = $self->get_template({ file => "${base}_${short}.tt" });};
        }
    }

    #DEFAULT => [base].tt (RebuildElasticSearch.tt)
    $template = $self->get_template({ file => "${base}.tt" }) unless defined $template;
    return $template;
}

# ------------------------------- Plugin ---------------------------------

sub new {
    my ($class, $args) = @_;
    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub tool {
    my ($self) = @_;
    my $cgi = $self->{'cgi'};

    my ($bib_index, $auth_index) = _index_names();

    my $count_biblios_before = _count_docs($bib_index);
    my $count_authorities_before = _count_docs($auth_index);

    my $outputs = '';
    my @log;

    if (uc($cgi->request_method()) eq 'POST') {
        my $cfg = _read_form($cgi);

        my ($miss, $which) = _indexes_missing($cfg->{biblios}, $cfg->{authorities});

        if ($miss && $cfg->{mode} eq 'update') {
            push @log,
                "ERREUR: Les index suivants n'existent pas: " . join(', ', @$which),
                "Astuce: cochez 'Supprimer' (delete) ou 'Reset' pour initialiser les index avant l'indexation.";
            $outputs = join("\n", @log);

        }
        else {
            push @log, sprintf("STARTING... \nmode=%s; targets=%s; batch=%d; desc=%s\n",
                $cfg->{mode},
                join(',', grep {$cfg->{$_}} qw(biblios authorities)),
                $cfg->{commit},
                $cfg->{desc} ? 'oui' : 'non');

            try {
                if ($cfg->{biblios}) {
                    _prepare_index_if_needed('biblios', $cfg, \@log);

                    if ($cfg->{bnumber}) {
                        _reindex_biblio($cfg->{bnumber}, \@log);
                    }
                    else {
                        _reindex_biblios($cfg, \@log);
                    }

                }
                if ($cfg->{authorities}) {
                    _prepare_index_if_needed('authorities', $cfg, \@log);

                    if ($cfg->{authid}) {
                        _reindex_authority($cfg->{authid}, \@log);
                    }
                    else {
                        _reindex_authorities($cfg, \@log);
                    }
                }
                push @log, "\nDONE";
            }
            catch {
                chomp $_;
                push @log, "ERROR: $_";
            };

            $outputs = join("\n", @log);
        }
    }

    my $count_biblios_after = _count_docs($bib_index);
    my $count_authorities_after = _count_docs($auth_index);

    my $server = _server_label();
    my $es_params = _es('biblios')->get_elasticsearch_params;
    my $index_base = $es_params->{index_name} // '';

    my $template = _resolve_template($self, $cgi, 'RebuildElasticSearch');
    $template->param(
        server                  => $server,
        index_name              => $index_base,
        count_authorities       => $count_authorities_before,
        count_biblios           => $count_biblios_before,
        count_authorities_after => $count_authorities_after,
        count_biblios_after     => $count_biblios_after,
        global_outputs          => $outputs,
    );

    print $cgi->header(-type => 'text/html', -charset => 'utf-8');
    print $template->output();
}

sub uninstall() {return 1;}

1;
