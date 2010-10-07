%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2008 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Mochiweb interface for webmachine.
-module(webmachine_mochiweb).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([start/1, start/2, stop/0, stop/1, loop/1]).

-include("webmachine_logger.hrl").
-include_lib("wm_reqdata.hrl").

start(Options) ->
    start(?MODULE, Options).
    
start(Name, Options) ->
    {DispatchList, Options1} = get_option(dispatch, Options),
    {ErrorHandler0, Options2} = get_option(error_handler, Options1),
    {EnablePerfLog, Options3} = get_option(enable_perf_logger, Options2),
    ErrorHandler = 
        case ErrorHandler0 of 
            undefined ->
                webmachine_error_handler;
            EH -> EH
        end,
    {LogDir, Options4} = get_option(log_dir, Options3),
    webmachine_sup:start_logger(LogDir),
    case EnablePerfLog of
        true ->
            application:set_env(webmachine, enable_perf_logger, true),
            webmachine_sup:start_perf_logger(LogDir);
        _ ->
            ignore
    end,
    application:set_env(webmachine, dispatch_list, DispatchList),
    application:set_env(webmachine, error_handler, ErrorHandler),
    mochiweb_http:start([{name, Name}, {loop, fun loop/1} | Options4]).

stop() ->
    stop(?MODULE).

stop(Name) ->
    mochiweb_http:stop(Name).
    

loop(MochiReq) ->
    ReqData = webmachine:init_reqdata(mochiweb, MochiReq),
    Host = case host_headers(ReqData) of
               [H|_] -> H;
               [] -> []
           end,
    Path = wrq:path(ReqData),
    {Dispatch, ReqDispatch} = case application:get_env(webmachine, dispatcher) of
                                  {ok, Dispatcher} ->
                                      Dispatcher:dispatch(Host, Path, ReqData);
                                  undefined ->
                                      {ok, DispatchList} = application:get_env(webmachine, dispatch_list),
                                      {webmachine_dispatcher:dispatch(Host, Path, DispatchList), ReqData}
                              end,
    case Dispatch of
        {no_dispatch_match, _UnmatchedHost, _UnmatchedPathTokens} ->
            {ok, ErrorHandler} = application:get_env(webmachine, error_handler),
            {ErrorHTML,ReqState1} = ErrorHandler:render_error(404, ReqDispatch, {none, none, []}),
            ReqState2 = webmachine_request:append_to_response_body(ErrorHTML, ReqState1),
            {ok,ReqState3} = webmachine_request:send_response(404, ReqState2),
            LogData = webmachine_request:log_data(ReqState3),
            case application:get_env(webmachine,webmachine_logger_module) of
                {ok, LogModule} ->
                    spawn(LogModule, log_access, [LogData]);
                _ -> nop
            end;
        {Mod, ModOpts, HostTokens, Port, PathTokens, Bindings, AppRoot, StringPath} ->
            BootstrapResource = webmachine_resource:new(x,x,x,x),
            {ok, Resource} = BootstrapResource:wrap(ReqData, Mod, ModOpts),
            {ok,RD1} = webmachine_request:load_dispatch_data(Bindings,HostTokens,Port,PathTokens,AppRoot,StringPath,ReqDispatch),
            {ok,RD2} = webmachine_request:set_metadata('resource_module', Mod, RD1),
            try 
                case webmachine_decision_core:handle_request(Resource, RD2) of
                    {_, RsFin, RdFin} ->
                        EndTime = now(),
                        {_, RdResp} = webmachine_request:send_response(RdFin),
                        LogData0 = webmachine_request:log_data(RdResp),
                        spawn(fun() -> webmachine_decision_core:do_log(LogData0#wm_log_data{resource_module=Mod, end_time=EndTime}) end),
                        RsFin:stop(),
                        ok;
                    {upgrade, UpgradeFun, RsFin, RdFin} ->
                        RsFin:stop(),
                        Mod:UpgradeFun(RdFin, RsFin:modstate()),
                        erlang:put(mochiweb_request_force_close, true)
                end
            catch
                error:_ -> 
                    ?WM_DBG({error, erlang:get_stacktrace()}),
                    {ok,RD3} = webmachine_request:send_response(500, RD2),
                    case application:get_env(webmachine, webmachine_logger_module) of
                        {ok, LogModule} -> 
                            spawn(LogModule, log_access, [webmachine_request:log_data(RD3)]);
                        _ ->
                            nop
                    end
            end;
        handled ->
            nop
    end.

get_option(Option, Options) ->
    get_option(Option, Options, undefined).

get_option(Option, Options, Default) ->
    {proplists:get_value(Option, Options, Default), proplists:delete(Option, Options)}.
    
host_headers(ReqData) ->
    [ V || V <- [wrq:get_req_header_lc(H, ReqData)
                 || H <- ["x-forwarded-host",
                          "x-forwarded-server",
                          "host"]],
     V /= undefined].
           
