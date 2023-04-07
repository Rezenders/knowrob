:- module(mongolog_triple,
        [ mng_triple_doc(t,-,t),
          triple(t,t,t),
          get_unique_name(r,-),
          is_unique_name(r),
          drop_graph(+),
          auto_drop_graphs/0,
          mongo_rdf_current_predicate/2,
          update_rdf_predicates/0
        ]).
/** <module> Handling of triples in query expressions.

The following predicates are supported:

| Predicate            | Arguments |
| ---                  | ---       |
| triple/3         | ?Subject, ?Property, ?Value |

@author Daniel Beßler
@license BSD
*/

:- use_module(library('semweb/rdf_db'),
		[ rdf_meta/1, rdf_equal/2 ]).
:- use_module(library('blackboard'), [ current_reasoner_module/1 ]).
:- use_module(library('mongodb/client')).
:- use_module(library('mongolog/mongolog')).
:- use_module(library('mongolog/mongolog_test')).
:- use_module(library('semweb')).

:- rdf_meta(taxonomical_property(r)).
:- rdf_meta(must_propagate_assert(r)).
:- rdf_meta(lookup_parents_property(t,t)).
:- rdf_meta(triple(t,t,t)).


%% mongo_rdf_current_predicate(Reasoner,PredicateName) is nondet.
%
% Stores all predicates that are defined in a reasoner database backend.
%
:- dynamic mongo_rdf_current_predicate/2.

%% register query commands
:- mongolog:add_command(triple).

%%
mongolog:step_expand(project(triple(S,P,O)),
                     assert(triple(S,P,O))) :- !.

%%
mongolog:step_compile(assert(triple(S,P,term(O))), Ctx, Pipeline, StepVars) :-
	% HACK: convert term(A) argument to string.
	%       it would be better to store lists/terms directly without conversion.
	ground(O),!,
	( atom(O) -> Atom=O ; term_to_atom(O, Atom) ),
	mongolog:step_compile(assert(triple(S,P,string(Atom))), Ctx, Pipeline, StepVars).

mongolog:step_compile(triple(S,P,term(O)), Ctx, Pipeline, StepVars) :-
	% HACK: convert term(A) argument to string.
	%       it would be better to store lists/terms directly without conversion.
	ground(O),!,
	( atom(O) -> Atom=O ; term_to_atom(O, Atom) ),
	mongolog:step_compile(triple(S,P,string(Atom)), Ctx, Pipeline, StepVars).

%%
mongolog:step_compile(assert(triple(S,P,O)), Ctx, Pipeline, StepVars) :-
	% add step variables to compile context
	triple_step_vars(triple(S,P,O), Ctx, StepVars0),
	mongolog:add_assertion_var(StepVars0, StepVars),
	merge_options([step_vars(StepVars)], Ctx, Ctx0),
	% create pipeline
	compile_assert(triple(S,P,O), Ctx0, Pipeline).

%%
mongolog:step_compile(triple(S,P,O), Ctx, Pipeline, StepVars) :-
	% add step variables to compile context
	triple_step_vars(triple(S,P,O), Ctx, StepVars),
	merge_options([step_vars(StepVars)], Ctx, Ctx0),
	% create pipeline
	compile_ask(triple(S,P,O), Ctx0, Pipeline).

%%
triple_step_vars(triple(S,P,O), Ctx, StepVars) :-
	(	bagof(Var,
			(	mongolog:goal_var([S,P,O], Ctx, Var)
			;	mongolog:context_var(Ctx, Var)
			% HACK: remember that variable is wrapped in term/1
			;	(	nonvar(O),
					O=term(O1),
					var(O1),
					mongolog:var_key(O1, Ctx, Key),
					Var=[Key,term(O1)]
				)
			),
			StepVars)
	;	StepVars=[]
	).

%%
% ask(triple(S,P,O)) uses $lookup to join input documents with
% the ones matching the triple pattern provided.
%
compile_ask(triple(S,P,O), Ctx, Pipeline) :-
	% add additional options to the compile context
	extend_context(triple(S,P,O), P1, Ctx, Ctx0),
	findall(LookupStep,
		lookup_triple(triple(S,P1,O), Ctx0, LookupStep),
		LookupSteps),
	LookupSteps \== [],
	% compute steps of the aggregate pipeline
	findall(Step,
		% filter out documents that do not match the triple pattern.
		% this is done using $match or $lookup operators.
		(	member(Step, LookupSteps)
		% compute the intersection of scope so far with scope of next document
		;	mongolog_scope_intersect('v_scope',
				string('$next.scope.time.since'),
				string('$next.scope.time.until'),
				Ctx0, Step)
		% the triple doc contains parents of the P at p*
		% and parents of O at o*.
		% these can be unwinded to yield a solution for each parent.
		;	unwind_parents(Ctx0, Step)
		% project new variable groundings
		;	set_triple_vars(S,P1,O,Ctx0,Step)
		% remove next field again
		;	Step=['$unset',string('next')]
		),
		Pipeline
	).

%%
% assert(triple(S,P,O)) uses $lookup to find matching triples
% with overlapping scope which are toggled to be removed in next stage.
% then the union of their scopes is computed and used for output document.
%
compile_assert(triple(S,P,O), Ctx, Pipeline) :-
	% add additional options to the compile context
	extend_context(triple(S,P,O), P1, Ctx, Ctx0),
	option(collection(Collection), Ctx0),
	option(query_scope(Scope), Ctx0),
	triple_graph(Ctx0, Graph),
	mongolog_time_scope(Scope, SinceTyped, UntilTyped),
	% throw instantiation_error if one of the arguments was not referred to before
	mongolog:all_ground([S,O], Ctx),
	% resolve arguments
	mongolog:var_key_or_val(S, Ctx, S_query),
	mongolog:var_key_or_val(O, Ctx, V_query),
	% special handling for RDFS semantic
	% FIXME: with below code P can not be inferred in query
	(	taxonomical_property(P1)
	->	( Pstar=array([string(P1)]), Ostar=string('$directParents') )
	;	( Pstar=string('$directParents'),  Ostar=array([V_query]) )
	),
	% build triple docuemnt
	TripleDoc=[
		['s', S_query], ['p', string(P1)], ['o', V_query],
		['p*', Pstar], ['o*', Ostar],
		['graph', string(Graph)],
		['scope', string('$v_scope')]
	],
	% configure the operation performed on scopes.
	% the default is to compute the union of scopes.
	(	option(intersect_scope, Ctx)
	->	(SinceOp='$max', UntilOp='$min')
	;	(SinceOp='$min', UntilOp='$max')
	),
	% compute steps of the aggregate pipeline
	% TODO: if just one document, update instead of delete
	findall(Step,
		% assign v_scope field. 
		(	Step=['$set', ['v_scope', [['time',[
					['since', SinceTyped],
					['until', UntilTyped]
			]]]]]
		% lookup documents that overlap with triple into 'next' field,
		% and toggle their delete flag to true
		;	delete_overlapping(triple(S,P,O), SinceTyped, UntilTyped, Ctx0, Step)
		% lookup parent documents into the 'parents' field
		;	lookup_parents(triple(S,P1,O), Ctx0, Step)
		% update v_scope.time.since
		;	reduce_num_array(string('$next'), SinceOp,
				'scope.time.since', 'v_scope.time.since', Step)
		% get max until of scopes in $next, update v_scope.time.until
		;	reduce_num_array(string('$next'), UntilOp,
				'scope.time.until', 'v_scope.time.until', Step)
		% add triples to triples array that have been queued to be removed
		;	mongolog:add_assertions(string('$next'), Collection, Step)
		% add merged triple document to triples array
		;	mongolog:add_assertion(TripleDoc, Collection, Step)
		;	(	once(must_propagate_assert(P)),
				propagate_assert(S, Ctx0, Step)
			)
		),
		Pipeline
	).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% LOOKUP triple documents
%%%%%%%%%%%%%%%%%%%%%%%

%%
lookup_triple(triple(S,P,V), Ctx, Step) :-
	\+ memberchk(transitive, Ctx),
	memberchk(collection(Coll), Ctx),
	memberchk(step_vars(StepVars), Ctx),
	% TODO: revise below
	mng_triple_doc(triple(S,P,V), QueryDoc, Ctx),
	(	memberchk(['s',_],QueryDoc)
	->	StartValue='$start.s'
	;	StartValue='$start.o'
	),
	%
	(	taxonomical_property(P)
	->	( Key_p='$p',  Key_o='$o*' )
	;	( Key_p='$p*', Key_o='$o' )
	),
	findall(MatchQuery,
		% first match what is grounded in compile context
		(	MatchQuery=QueryDoc
		% next match variables grounded in call context
		;	(	member([Arg,FieldValue],[[S,'$s'],[P,Key_p],[V,Key_o]]),
				triple_arg_var(Arg, ArgVar),
				mongolog:var_key(ArgVar, Ctx, ArgKey),
				atom_concat('$$',ArgKey,ArgValue),
				atom_concat(ArgValue,'.type',ArgType),
				triple_arg_value(Arg, ArgValue, FieldValue, Ctx, ArgExpr),
				MatchQuery=['$expr', ['$or', array([
					% pass through if var is not grounded
					['$eq', array([string(ArgType), string('var')])],
					ArgExpr % else perform a match
				])]]
			)
		;	mongolog_scope_match(Ctx, MatchQuery)
		;	graph_match(Ctx, MatchQuery)
		),
		MatchQueries
	),
	%
	findall(InnerStep,
		% match input triples with query pattern
		(	(	MatchQueries=[FirstMatch]
			->	InnerStep=['$match', FirstMatch]
			;	InnerStep=['$match', ['$and', array(MatchQueries)]]
			)
		% limit results if requested
		;	(	member(limit(Limit),Ctx),
				InnerStep=['$limit',int(Limit)]
			)
		),
		InnerPipeline
	),
	% pass input document values to lookup
	mongolog:lookup_let_doc(StepVars, LetDoc),
	% lookup matching documents and store in 'next' field
    (	Step=['$lookup', [
			['from',string(Coll)],
			['as',string('next')],
			['let',LetDoc],
			['pipeline', array(InnerPipeline)]
		]]
	% add additional results if P is a reflexive property
	;	(	memberchk(reflexive,Ctx),
			(	Step=['$unwind',string('$next')]
			;	Step=['$set', ['start', string('$next')]]
			;	Step=['$set', ['next', array([string('$next')])]]
			;	reflexivity(StartValue, Ctx, Step)
			)
		)
	% at this point 'next' field holds an array of matching documents
	% that is unwinded here.
	;	Step=['$unwind',string('$next')]
	).

%%
lookup_triple(triple(S,P,V), Ctx, Step) :-
	% read options
	option(transitive, Ctx),
	option(collection(Coll), Ctx),
	mongolog_one_db(_DB, OneColl),
	% infer lookup parameters
	mng_query_value(P,Query_p),
	% TODO: can query operators be supported?
	mng_strip_variable(S, S0),
	mng_strip_variable(V, V0),
	mongolog:var_key_or_val(S0, Ctx, S_val),
	mongolog:var_key_or_val(V0, Ctx, V_val),
	
	% FIXME: a runtime condition is needed to cover the case where S was
	%        referred to in ignore'd goal that failed.
	(	has_value(S0,Ctx)
	->	( Start=S_val, To='s', From='o', StartValue='$start.s' )
	;	( Start=V_val, To='o', From='s', StartValue='$start.o' )
	),
	
	% match doc for restring the search
	findall(Restriction,
		(	Restriction=['p*',Query_p]
		% TODO: see how scope can be included
		%;	graph_doc(Graph,Restriction)
		%;	scope_doc(Scope,Restriction)
		),
		MatchDoc
	),
	% recursive lookup
	(	Step=['$graphLookup', [
			['from',                    string(Coll)],
			['startWith',               Start],
			['connectToField',          string(To)],
			['connectFromField',        string(From)],
			['as',                      string('t_paths')],
			['depthField',              string('depth')],
			['restrictSearchWithMatch', MatchDoc]
		]]
	% $graphLookup does not ensure order, so we need to order by recursion depth
	% in a separate step
	;	Step=['$lookup', [
			['from',     string(OneColl)],
			['as',       string('t_sorted')],
			['let',      [['t_paths', string('$t_paths')]]],
			['pipeline', array([
				['$set',         ['t_paths', string('$$t_paths')]],
				['$unwind',      string('$t_paths')],
				['$replaceRoot', ['newRoot', string('$t_paths')]],
				['$sort',        ['depth', integer(1)]]
			])]
		]]
	;	Step=['$set', ['next', string('$t_sorted')]]
	;	Step=['$set', ['start', ['$arrayElemAt',
			array([string('$next'), integer(0)])
		]]]
	;	Step=['$unset', string('t_paths')]
	;	Step=['$unset', string('t_sorted')]
	% add additional triple in next if P is a reflexive property
	;	reflexivity(StartValue, Ctx, Step)
	% iterate over results
	;	Step=['$unwind',string('$next')]
	% match values with expression given in query
	;	(	To=='s', has_value(V0,Ctx),
			Step=['$match', ['next.o', V_val]]
		)
	).

%%
% FIXME: need to do runtime check for ignored goals!
%
has_value(X, _Ctx) :-
	ground(X),!.
has_value(X, Ctx) :-
	term_variables(X,Vars),
	member(Var,Vars),
	mongolog:is_referenced(Var, Ctx).

%%
reflexivity(StartValue, Ctx, Step) :-
	memberchk(reflexive,Ctx),
	(	Step=['$set', ['t_refl', [
			['s',string(StartValue)],
			['p',string('$start.p')],
			['p*',string('$start.p*')],
			['o',string(StartValue)],
			['o*',array([string(StartValue)])],
			['graph',string('$start.graph')],
			['scope',string('$start.scope')]
		]]]
	;	Step=['$set', ['next', ['$concatArrays',
			array([array([string('$t_refl')]), string('$next')])
		]]]
	;	Step=['$unset', array([string('t_refl'),string('start')])]
	).

%%
delete_overlapping(triple(S,P,V), SinceTyped, UntilTyped, Ctx,
		['$lookup', [
			['from',string(Coll)],
			['as',string('next')],
			['let',LetDoc],
			['pipeline',array(Pipeline)]
		]]) :-
	memberchk(collection(Coll), Ctx),
	memberchk(step_vars(StepVars), Ctx),
	% read triple data
	mongolog:var_key_or_val1(P, Ctx, P0),
	mongolog:var_key_or_val1(S, Ctx, S0),
	mongolog:var_key_or_val1(V, Ctx, V0),
	% set Since=Until in case of scope intersection.
	% this is to limit to results that do hold at Until timestamp.
	% FIXME: when overlap yields no results, zero is used as since
	%        by until. but then the new document could overlap
	%        with existing docs, which is not wanted.
	%		 so better remove special handling here?
	%        but then the until time maybe is set to an unwanted value? 
	(	option(intersect_scope, Ctx)
	->	Since0=UntilTyped
	;	Since0=SinceTyped
	),
	mongolog:lookup_let_doc(StepVars, LetDoc),
	% build pipeline
	findall(Step,
		% $match s,p,o and overlapping scope
		(	Step=['$match',[
				['s',S0], ['p',P0], ['o',V0],
				['scope.time.since',['$lte',UntilTyped]],
				['scope.time.until',['$gte',Since0]]
			]]
		% only keep scope field
		;	Step=['$project',[['scope',int(1)]]]
		% toggle delete flag
		;	Step=['$set',['delete',bool(true)]]
		),
		Pipeline
	).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% RDFS
%%%%%%%%%%%%%%%%%%%%%%%

%%
taxonomical_property(P) :- var(P),!,fail.
taxonomical_property(Term) :-
	compound(Term),!,
	Term =.. [_Functor,Arg],
	taxonomical_property(Arg).
taxonomical_property(rdf:type).
taxonomical_property(rdfs:subClassOf).
taxonomical_property(rdfs:subPropertyOf).

%%
unwind_parents(Context, Step) :-
	option(pstar, Context),
	(	Step=['$unwind', string('$next.p*')]
	;	Step=['$set', ['next.p', ['$next.p*']]]
	).
unwind_parents(Context, Step) :-
	option(ostar, Context),
	(	Step=['$unwind', string('$next.o*')]
	;	Step=['$set', ['next.o', string('$next.o*')]]
	).

%% set "parents" field by looking up subject+property then yielding o* field
lookup_parents_property(triple(_,rdf:type,O),           [O,rdfs:subClassOf]).
lookup_parents_property(triple(_,rdfs:subClassOf,O),    [O,rdfs:subClassOf]).
lookup_parents_property(triple(_,rdfs:subPropertyOf,P), [P,rdfs:subPropertyOf]).
lookup_parents_property(triple(_,P,_),                  [P,rdfs:subPropertyOf]).

%%
lookup_parents(Triple, Context, Step) :-
	memberchk(collection(Coll), Context),
	once(lookup_parents_property(Triple, [Child, Property])),
	% make sure value is wrapped in type term
	mng_typed_value(Child,   TypedValue),
	mng_typed_value(Property,TypedProperty),
	% first, lookup matching documents and yield o* in parents array
	(	Step=['$lookup', [
			['from',string(Coll)],
			['as',string('directParents')],
			['pipeline',array([
				['$match', [
					['s',TypedValue],
					['p',TypedProperty]
				]],
				['$project', [['o*', int(1)]]],
				['$unwind', string('$o*')]
			])]
		]]
	% convert parents from list of documents to list of strings.
	;	Step=['$set',['directParents',['$map',[
			['input',string('$directParents')],
			['in',string('$$this.o*')]
		]]]]
	% also add child to parents list
	;	array_concat('directParents', array([TypedValue]), Step)
	).

%%
propagate_assert(S, Context, Step) :-
	memberchk(collection(Collection), Context),
	mng_typed_value(S,TypedS),
	% the inner lookup matches documents with S in o*
	findall(X,
		% match every document with S in o*
		(	X=['$match', [['o*',TypedS]]]
		% and add parent field from input documents to o*
		;	array_concat('o*', string('$$directParents'), X)
		% only replace o*
		;	X=['$project',[['o*',int(1)]]]
		),
		Inner),
	% first, lookup matching documents and update o*
	(	Step=['$lookup', [
			['from',string(Collection)],
			['as',string('next')],
			['let',[['directParents',string('$directParents')]]],
			['pipeline',array(Inner)]
		]]
	% second, add each document to triples array
	;	mongolog:add_assertions(string('$next'), Collection, Step)
	).

%% the properties for which assertions must be propagated
must_propagate_assert(rdfs:subClassOf).
must_propagate_assert(rdfs:subPropertyOf).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% triple/3 query pattern
%%%%%%%%%%%%%%%%%%%%%%%

%% triple(?Subject, ?Property, ?Value) is nondet.
%
% Query values of a property (and their sub-properties) on some subject in the triple DB.
% If the property is rdfs:subPropertyOf or rdf:type the query returns the values for the 
% subject and their super-class
% 
% The property can be wrapped in one of several options:
% 
%     - transitive(Property) 
%       indicates that the property is transitive
%     - reflexive(Property)
%       indicates that the property is reflexive
%     - pstar(Property)
%       binds the property to one of the values in the p* field in the mongodb
%
% The value can be wrapped in one of several options:
%
%     - ostar(Value)
%       binds the value to one of the values in the o* field in the mongodb
%
% @param Subject The subject of a triple.
% @param Property The predicate of a triple.
% @param Value The object of a triple.
%
triple(S,P,O) :-
	mongolog_call(triple(S,P,O)).

%% mng_triple_doc(+Triple, -Doc, +Context) is semidet.
%
% Translate a triple term into a mongo query document.
%
mng_triple_doc(triple(S,P,V), Doc, Context) :-
	%% read options
	triple_graph(Context, Graph),
	option(query_scope(Scope), Context, dict{}),
	% special handling for some properties
	(	taxonomical_property(P)
	->	( Key_p='p',  Key_o='o*' )
	;	( Key_p='p*', Key_o='o' )
	),
	% strip term ->(Term,Var)
	mng_strip_variable(S, S1),
	mng_strip_variable(P, P1),
	mng_strip_variable(V, V1),
	% get the query pattern
	% FIXME: mng_query_value may silently fail on invalid input and this rule still succeeds
	findall(X,
		(	( mng_query_value(S1,Query_s), X=['s',Query_s] )
		;	( mng_query_value(P1,Query_p), X=[Key_p,Query_p] )
		;	( mng_query_value(V1,Query_v), \+ is_term_query(Query_v), X=[Key_o,Query_v] )
		;	graph_doc(Graph,X)
		;	mongolog_scope_doc(Scope,X)
		),
		Doc
	),
	% ensure doc has value if input is grounded
	once((\+ ground(S1) ; memberchk(['s',_],Doc))),
	once((\+ ground(P1) ; memberchk([Key_p,_],Doc))),
	once((\+ ground(V1) ; memberchk([Key_o,_],Doc))).

%%
is_term_query([[type,string(compound)],_]).
is_term_query([_, [[type,string(compound)],_]]).

%%
triple_arg_var(Arg, ArgVar) :-
	mng_strip_variable(Arg, X),
	term_variables(X, [ArgVar]).

%%
triple_arg_value(_Arg, ArgValue, FieldValue, _Ctx, ['$in',
		array([ string(ArgValue), string(FieldValue) ])]) :-
	% FIXME: operators are ignored!!
	% TODO: can be combined with other operators??
	atom_concat(_,'*',FieldValue),!.
	
triple_arg_value(Arg, ArgValue, FieldValue, _Ctx, [ArgOperator,
		array([ string(FieldValue), string(ArgValue) ])]) :-
	mng_strip_variable(Arg, X),
	mng_strip_operator(X, Operator1, _),
	mng_operator(Operator1, ArgOperator).

%%
graph_doc('*', _)    :- !, fail.
graph_doc('user', _) :- !, fail.
graph_doc(=(GraphName), ['graph',string(GraphName)]) :- !.
graph_doc(  GraphName,  ['graph',['$in',array(Graphs)]]) :-
	ground(GraphName),!,
	findall(string(X),
		(X=GraphName ; sw_graph_includes(GraphName,X)),
		Graphs).

%%
graph_match(Ctx, ['$expr', [Operator,
		array([ string(GraphValue), ArgVal ])
	]]) :-
	triple_graph(Ctx, Graph),
	graph_doc(Graph, [GraphKey, Arg]),
	atom_concat('$',GraphKey,GraphValue),
	(	(   is_list(Arg), Arg=[Operator,ArgVal])
	;	(\+ is_list(Arg), Arg=[ArgVal], Operator='$eq')
	).

%% drop_graph(+Name) is det.
%
% Deletes all triples asserted into given named graph.
%
% @param Name the graph name.
%
drop_graph(Name) :-
	mongolog_get_db(DB, Coll, 'triples'),
	mng_remove(DB, Coll, [[graph, string(Name)]]).

%%
% Drop graphs on startup if requested through settings.
% This is usually done to start with an empty "user" graph
% when KnowRob is started.
%
auto_drop_graphs :-
	\+ reasoner_setting(mongodb:read_only, true),
	reasoner_setting(mongodb:drop_graphs, L),
	forall(member(X,L), drop_graph(X)).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% helper
%%%%%%%%%%%%%%%%%%%%%%%

%%
triple_graph(Ctx, Graph) :-
	once((sw_default_graph(DefaultGraph) ; DefaultGraph=user)),
	option(graph(Graph), Ctx, DefaultGraph).

%%
extend_context(triple(_,P,_), P1, Context, Context0) :-
	% get the collection name
	(	option(collection(Coll), Context)
	;	mongolog_get_db(_DB, Coll, 'triples')
	),
	% read options from argument terms
	% e.g. properties can be wrapped in transitive/1 term to
	% indicate that the property is transitive which will then
	% generate an additional step in the aggregate pipeline.
	strip_property_modifier(P,P_opts,P1),
	% extend the context
	% NOTE: do not use findall here to keep var references in Context valid
	bagof(Opt,
		(	Opt=property(P1)
		;	Opt=collection(Coll)
		;	member(Opt, P_opts)
		;	member(Opt, Context)
		),
		Context0).

%%
get_triple_vars(S, P, O, Ctx, Vars) :-
	findall([Key,Field],
		(	member([Field,Arg], [[s,S],[p,P],[o,O]]),
			mongolog:goal_var(Arg, Ctx, [Key, _Var])
		),
		Vars).

%%
set_triple_vars(S, P, O, Ctx, ['$set', ProjectDoc]) :-
	get_triple_vars(S,P,O,Ctx,TripleVars),
	findall([Key, string(NextValue)],
		(	member([Key, Field], TripleVars),
			atom_concat('$next.', Field, NextValue)
		),
		ProjectDoc),
	ProjectDoc \= [].

%%
strip_property_modifier(Var,[],Var) :- var(Var), !.
strip_property_modifier(Term,[X|Xs],Stripped) :-
	strip_property_modifier1(Term,X,Term0), !,
	strip_property_modifier(Term0,Xs,Stripped).
strip_property_modifier(Stripped,[],Stripped).

strip_property_modifier1(transitive(X),      ostar,      X) :- taxonomical_property(X),!.
strip_property_modifier1(transitive(X),      transitive, X).
strip_property_modifier1(reflexive(X),       reflexive,  X).
strip_property_modifier1(include_parents(X), pstar,      X).

%%
array_concat(Key,Arr,['$set',
		[Key,['$setUnion',
			array([string(Arr0),Arr])]
		]]) :-
	atom_concat('$',Key,Arr0).

%%
reduce_num_array(ArrayKey, Operator, Path, ValKey, Step) :-
	atom_concat('$$this.', Path, Path0),
	atom_concat('$', ValKey, ValKey0),
	(	Step=['$set',['num_array',['$map',[
			['input', ArrayKey],
			['in', string(Path0)]
		]]]]
	;	array_concat('num_array', array([string(ValKey0)]), Step)
	;	Step=['$set', [ValKey, [Operator, string('$num_array')]]]
	;	Step=['$unset',string('num_array')]
	).

%% update_rdf_predicates is det.
%
% Read all properties defined in the database, and assert
% mongo_rdf_current_predicate/2 for each of them.
%
update_rdf_predicates :-
    current_reasoner_module(Reasoner),
	mongolog_get_db(DB, Coll, 'triples'),
	rdf_equal(rdf:'type',RDFType),
	rdf_equal(rdf:'Property',PropertyType),
    retractall(mongo_rdf_current_predicate(Reasoner, _)),
	forall(
	    mng_find(DB, Coll, [
	        ['p', string(RDFType)],
	        ['o*', string(PropertyType)]
	    ],  Doc),
	    (   mng_get_dict('s', Doc, string(PropertyName)),
	        define_property(Reasoner, PropertyName)
	    )
	).

%%
define_property(Property) :-
    current_reasoner_module(Reasoner),
    define_property(Reasoner, Property).
define_property(Reasoner, Property) :-
    mongo_rdf_current_predicate(Reasoner, Property), !.
define_property(Reasoner, Property) :-
    assertz(mongo_rdf_current_predicate(Reasoner, Property)).

%% is_unique_name(+Name) is semidet.
%
% True if Name is not the subject of any known fact.
%
is_unique_name(Name) :-
	mongolog_get_db(DB, Coll, 'triples'),
	\+ mng_find(DB, Coll, [['s',string(Name)]], _).

%% get_unique_name(+Prefix, -Name) is semidet.
%
% Generates a unique name with given prefix.
%
get_unique_name(Prefix, Name) :-
	% generate 8 random alphabetic characters
	randseq(8, 25, Seq_random),
	maplist(plus(65), Seq_random, Alpha_random),
	atom_codes(Sub, Alpha_random),
	% TODO: what IRI prefix? Currently we re-use the one of the type.
	%        but that seems not optimal. Probably best to
	%        have this in query context, and some meaningful default.
	atomic_list_concat([Prefix,'_',Sub], IRI),
	% check if there is no triple with this identifier as subject or object yet
	(	is_unique_name(IRI)
	->	Name=IRI
	;	unique_name(Prefix,Name)
	).
