use MooseX::Declare;

class SQL::Abstract::AST::v1 extends SQL::Abstract {

  use Carp qw/croak/;
  use Data::Dump qw/pp/;

  use Moose::Util::TypeConstraints;
  use MooseX::Types::Moose qw/ArrayRef Str Int Ref HashRef/;
  use MooseX::AttributeHelpers;
  use SQL::Abstract::Types qw/AST ArrayAST HashAST/;

  clean;

  # set things that are valid in where clauses
  override _build_where_dispatch_table {
    return { 
      %{super()},
      -in => $self->can('_in'),
      -not_in => $self->can('_in'),
      map { +"-$_" => $self->can("_$_") } qw/
        value
        name
        true
        false
      /
    };
  }

  method _select(HashAST $ast) {
    # Default to requiring columns and from
    # Once TCs give better errors, make this a SelectAST type
    for (qw/columns from/) {
      confess "$_ key is required (and must be an AST) to select"
        unless is_ArrayAST($ast->{$_});
    }
   
    # Check that columns is a -list
    confess "columns key should be a -list AST, not " . $ast->{columns}[0]
      unless $ast->{columns}[0] eq '-list';

    my @output = (
      "SELECT", 
      $self->dispatch($ast->{columns}),
      "FROM",
      $self->dispatch($ast->{from})
    );

    for (qw/join/) {
      if (exists $ast->{$_}) {
        my $sub_ast = $ast->{$_};
        $sub_ast->{-type} = "$_" if is_HashRef($sub_ast);
        confess "$_ option is not an AST"
          unless is_AST($sub_ast);

        push @output, $self->dispatch($sub_ast);
      }
    }

    return join(' ', @output);
  }

  method _where(ArrayAST $ast) {
    my (undef, @clauses) = @$ast;
  
    return 'WHERE ' . $self->_recurse_where(\@clauses);
  }

  method _order_by(AST $ast) {
    my @clauses = @{$ast->{order_by}};
  
    my @output;
   
    for (@clauses) {
      if (is_ArrayRef($_) && $_->[0] =~ /^-(asc|desc)$/) {
        my $o = $1;
        push @output, $self->dispatch($_->[1]) . " " . uc($o);
        next;
      }
      push @output, $self->dispatch($_);
    }

    return "ORDER BY " . join(", ", @output);
  }

  method _name(AST $ast) {
    my @names = @{$ast->{args}};

    my $sep = $self->name_separator;
    my $quote = $self->is_quoting 
              ? $self->quote_chars
              : [ '' ];

    my $join = $quote->[-1] . $sep . $quote->[0];

    # We dont want to quote * in [qw/me */]: `me`.* is the desired output there
    # This means you can't have a field called `*`. I am willing to accept this
    # situation, cos thats a really stupid thing to want.
    my $post;
    $post = pop @names if $names[-1] eq '*';

    my $ret = 
      $quote->[0] . 
      join( $join, @names ) . 
      $quote->[-1];

    $ret .= $sep . $post if defined $post;
    return $ret;
  }

  method _join(HashRef $ast) {
  
    my $output = 'JOIN ' . $self->dispatch($ast->{tablespec});

    $output .= exists $ast->{on}
             ? ' ON (' . $self->_recurse_where( $ast->{on} )
             : ' USING (' .$self->dispatch($ast->{using} || croak "No 'on' or 'join' clause passed to -join");

    $output .= ")";
    return $output;
      
  }

  method _list(AST $ast) {
    my @items = @{$ast->{args}};

    return join(
      $self->list_separator,
      map { $self->dispatch($_) } @items);
  }

  method _alias(AST $ast) {
    
    # TODO: Maybe we want qq{ AS "$as"} here
    return $self->dispatch($ast->{ident}) . " AS " . $ast->{as};

  }

  method _value(ArrayAST $ast) {
    my ($undef, $value) = @$ast;

    $self->add_bind($value);
    return "?";
  }

  method _recurse_where(ArrayRef $clauses) {

    my $OP = 'AND';
    my $prio = $SQL::Abstract::PRIO{and};
    my $first = $clauses->[0];

    if (!ref $first) {
      if ($first =~ /^-(and|or)$/) {
        $OP = uc($1);
        $prio = $SQL::Abstract::PRIO{$1};
        shift @$clauses;
      } else {
        # If first is not a ref, and its not -and or -or, then $clauses
        # contains just a single clause
        $clauses = [ $clauses ];
      }
    }

    my $dispatch_table = $self->where_dispatch_table;

    my @output;
    foreach (@$clauses) {
      croak "invalid component in where clause: $_" unless is_ArrayRef($_);
      my $op = $_->[0];

      if ($op =~ /^-(and|or)$/) {
        my $sub_prio = $SQL::Abstract::PRIO{$1}; 

        if ($sub_prio <= $prio) {
          push @output, $self->_recurse_where($_);
        } else {
          push @output, '(' . $self->_recurse_where($_) . ')';
        }
      } else {
        push @output, $self->_where_component($_);
      }
    }

    return join(" $OP ", @output);
  }

  method _where_component(ArrayRef $ast) {
    my $op = $ast->[0];

    if (my $code = $self->lookup_where_dispatch($op)) { 
      
      return $code->($self, $ast);

    }
    croak "'$op' is not a valid clause in a where AST"
      if $op =~ /^-/;

    croak "'$op' is not a valid operator";
   
  }


  method _binop(ArrayRef $ast) {
    my ($op, $lhs, $rhs) = @$ast;

    join (' ', $self->_where_component($lhs), 
               $self->binop_mapping($op) || croak("Unknown binary operator $op"),
               $self->_where_component($rhs)
    );
  }

  method _in(ArrayAST $ast) {
    my ($tag, $field, @values) = @$ast;

    my $not = $tag =~ /^-not/ ? " NOT" : "";

    return $self->_false if @values == 0;
    return $self->_where_component($field) .
           $not. 
           " IN (" .
           join(", ", map { $self->dispatch($_) } @values ) .
           ")";
  }

  method _generic_func(ArrayRef $ast) {
  }

  # 'constants' that are portable across DBs
  method _false($ast?) { "0 = 1" }
  method _true($ast?) { "1 = 1" }

}
