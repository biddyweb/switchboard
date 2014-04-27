%% @doc supervise the idling IMAP process and the operator

-module(switchboard_idler).
-behaviour(supervisor).

%% Interface exports
-export([start_link/3]).

%% Callback exports
-export([init/1]).

%%==============================================================================
%% Interface exports
%%==============================================================================

%% @doc start the switchboard_idler supervisor as part of the supervision tree
-spec start_link(imap:connspec(), imap:auth(), imap:mailbox()) ->
    supervisor:startlink_ret().
start_link(ConnSpec, Auth, Mailbox) ->
    supervisor:start_link(?MODULE, {ConnSpec, Auth, Mailbox}).


%%==============================================================================
%% Callback exports
%%==============================================================================

init({ConnSpec, Auth, Mailbox}) ->
    RestartStrategy = one_for_one,
    MaxR = MaxT = 5,
    Account = imap:auth_to_username(Auth),
    ImapSpec = {imap,
                {imap, start_link,
                 [ConnSpec,
                  [{init_callback, 
                    imapswitchboard:register_callback(Account, {idler, Mailbox})},
                  {post_init_callback, spawn_login_idle(Auth, Mailbox)}]]},
                permanent,
                5000, %% TODO switch these out with an application var
                worker,
                [imap]},
    OperatorSpec = {switchboard_operator,
                    {switchboard_operator, start_link, [Account, Mailbox]},
                    permanent,
                    5000, %% TODO switch these out with an application var
                    worker,
                    [imap]},
    {ok, {{RestartStrategy, MaxR, MaxT}, [ImapSpec, OperatorSpec]}}.


%%==============================================================================
%% Internal functions.
%%==============================================================================

%% @doc PostInitCallback function to login+idle on the given mailbox.
spawn_login_idle(Auth, Mailbox) ->
    fun(State) ->
            Imap = self(),
            spawn_link(
              fun() ->
                      {ok, _} = imap:call(Imap, {login, Auth}),
                      {ok, _} = imap:call(Imap, {select, Mailbox}),
                      %% Setup the dispatch fun to forward to the oper via gproc
                      DispatchFun = switchboard_operator:dispatch_fun(
                                      imap:auth_to_username(Auth), Mailbox),
                      ok = imap:cast(Imap, idle, [{dispatch, DispatchFun}])
              end),
            State
    end.


%%==============================================================================
%% Eunit.
%%==============================================================================

-define(TEST, true).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

idler_test_() ->
    {foreach,
     fun idler_setup/0,
     fun idler_teardown/1,
     [fun reg_asserts/1]}.

-spec idler_setup() ->
    {{imap:connspec(), imap:auth()}, imap:mailbox(), pid()}.
idler_setup() ->
    {ConnSpec, Auth} = imapswitchboard:dispatch(),
    Mailbox = <<"INBOX">>,
    {ok, Pid} = start_link(ConnSpec, Auth, Mailbox),
    {{ConnSpec, Auth}, Mailbox, Pid}.

-spec idler_teardown({{imap:connspec(), imap:auth()}, imap:mailbox(), pid()}) ->
    ok.
idler_teardown({_, _, Pid}) ->
    true = exit(Pid, normal),
    ok.

%% @hidden assert that the the processes have registered
-spec reg_asserts({{imap:connspec(), imap:auth()}, imap:mailbox(), pid()}) ->
    [any()].
reg_asserts({{_ConnSpec, Auth}, Mailbox, _}) ->
    Account = imap:auth_to_username(Auth),
    [?_assert(is_pid(imapswitchboard:where(Account, {Type, Mailbox})))
     || Type <- [idler, operator]].

-endif.