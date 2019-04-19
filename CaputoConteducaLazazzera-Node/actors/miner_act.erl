-module(miner_act).
-export([start_M_act/2]).
-import (proof_of_work , [solve/1,check/2]).
-import (utils , [sendMessage/2,sleep/1]).



compute(PidRoot,PidBlock) ->
    PidBlock ! {minerReady,self()},
    % mi metto in attesa di un nuovo set di transazioni da inserire nel blocco
    receive 
    {createBlock, ID_blocco_prev, Transactions} ->
        % io:format("-> [~p] Sto minando il BLOCCO: ~p~n",[PidRoot,Transactions]),
        Solution = proof_of_work:solve({ID_blocco_prev, Transactions}),
        B = {make_ref(), ID_blocco_prev, Transactions, Solution},
        PidBlock ! {miningFinished, B},
        compute(PidRoot,PidBlock)
    end.

start_M_act(PidRoot,PidBlock) -> 
    sleep(1),
    compute(PidRoot,PidBlock).   