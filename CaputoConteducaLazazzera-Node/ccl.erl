-module(ccl).
-import (check_act , [start_C_act/1]).
-import (transaction_act , [start_T_act/2]).
-import (block_act , [start_B_act/1]).

-export([test/0,start/1]).

-on_load(load_module_act/0).

load_module_act() ->
    compile:file('teacher_node.erl'), 
    compile:file('actors/check_act.erl'), % attore che controlla la tipologia
    compile:file('actors/transaction_act'), % attore gestore delle transazioni
    compile:file('actors/block_act.erl'),
    compile:file('actors/block_gossiping_act.erl'), 
    compile:file('actors/chain_tools.erl'), 
    compile:file('actors/miner_act.erl'), 
    compile:file('proof_of_work.erl'),
    ok.  


sleep(N) -> receive after N*1000 -> ok end.
% Node è il nodo da monitorare
% Main è il nodo che vuole essere avvisato della morte di Node
% il watcher ogni 5s fa ping a Node 
% e se dopo 2s non risponde allora non è piu vivo
watch(Main,Node) ->
    sleep(5),
    Ref = make_ref(),
    Node ! {ping, self(), Ref},
    receive
        {pong, Ref} -> watch(Main,Node)
    after 2000 -> 
        Main ! {dead, Node}
    end.


loop(FriendsList, NameNode,PidT,PidB,PidC,Nonces) -> 
    receive 
        %! %%%%%%%%% DEBUG %%%%%%%%%%%
        {addNewNonce, Nonce} ->
            % io:format("ho aggiunto un nonce ~n"),
            loop(FriendsList,NameNode,PidT,PidB,PidC,Nonces++[Nonce]);
        {removeNonce, Nonce} ->
            % io:format("ho rimosso un nonce ~n"),
            loop(FriendsList,NameNode,PidT,PidB,PidC,Nonces--[Nonce]);
        {checkFriendsList, CheckAct} ->
            CheckAct ! {myFriendsList, FriendsList},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
        {printT} ->
            PidT ! {printT},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
        {print} -> 
            io:format("[~p, ~p]: ha questi amici: ~p~n",[self(),NameNode, FriendsList]),
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces); 
        {printC} ->
            PidB ! {printC},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
        {printTM} ->
            PidB ! {printTM},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);  

        %!%%%%%% Mantenimento Topologia %%%%%%%
        {ping, Mittente, Nonce} -> % sono vivo
            Mittente ! {pong, Nonce},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);                
    
        {get_friends, Mittente, Nonce} -> % qualcuno mi ha chiesto la lista di amici
            Mittente ! {friends, Nonce, FriendsList}, 
            % se Mittente non è nella FList lo aggiungo se ho meno di 3 amici
            case lists:member(Mittente, FriendsList) of
                    true -> loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
                    false -> 
                        case length(FriendsList) < 3 of 
                            true -> 
                                Self = self(), % per preservare il Pid-Root
                                % metto un watch su Mittente
                                spawn(fun()-> watch(Self, Mittente) end),
                                % io:format("[~p, ~p] ha un nuovo amico: ~p (in seguito ad una get_friends)~n",[self(),NameNode,Mittente]),
                                loop([Mittente | FriendsList], NameNode, PidT, PidB, PidC, Nonces);
                            false -> % non ho bisogno di altri amici
                                loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces)
                        end
            end;
        {friends, Nonce, Lista_di_amici} -> 
            %se ho il Nonce elaboro il mess
            case lists:member(Nonce, Nonces) of 
                true ->
                    %io:format("~p stava in ~p ~n",[Nonce, Nonces]),
                    NewNonces = Nonces--[Nonce],
                    ListTemp = ((Lista_di_amici -- [self()]) -- FriendsList),            
                    case length(ListTemp) =:= 0 of
                        true -> % non ho ricevuto amici "utili"
                            loop(FriendsList, NameNode, PidT, PidB, PidC, NewNonces);
                        false -> 
                            % prendo solo n amici per arrivare a 3
                            NewFriends = addNodes(length(FriendsList), ListTemp),
                            % io:format("[~p, ~p] ha ~p nuovi amici: ~p~n",[self(),NameNode,length(NewFriends),NewFriends]),
                            watchFriends(NewFriends,self()), % per amico un watcher 
                            NewList = NewFriends ++ FriendsList,
                            loop(NewList, NameNode, PidT, PidB, PidC, NewNonces)
                    end;
                false -> 
                    %io:format("~p NON stava in ~p ~n",[Nonce, Nonces]),
                    loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces)
            end;
        {dead, Node} ->
            % io:format("[~p, ~p]: ~p è morto~n",[self(),NameNode,Node]),
            NewList =  FriendsList -- [Node],
            loop(NewList, NameNode, PidT, PidB, PidC, Nonces);
        %!%%%%%%%%%%% GESTIONE TRANSAZIONI %%%%%%%%%%%%%
        % Push locale di una transazione all'attore delegato che provvede a fare gossiping di Transazione
        {push, Transazione} -> 
            % io:format("[~p, ~p]: Ho ricevuto la transazione ~p~n",[self(),NameNode,Transazione]),
            PidT ! {pushLocal, Transazione, FriendsList}, % si occupa di fare gossiping di T
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);

        %!%%%%%%%%%%% GESTIONE BLOCCHI %%%%%%%%%%%%%%%%%%
        % sender mi ha mandato questo blocco da rigirare
        {update, Sender, Blocco} ->
            % io:format("[~p, ~p]: Ho ricevuto l'update del blocco ~p~n",[self(),NameNode,Blocco]),
            PidB ! {updateLocal,Sender,Blocco},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);

        %!%%%%%%%%%%%% RICHIESTA INFO SULLA MIA CATENA %%%%%%%%%%%%%%
        {get_previous, Mittente, Nonce, Idblocco_precedente} ->
            PidB ! {get_previousLocal, Mittente, Nonce, Idblocco_precedente},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
        {get_head, Mittente, Nonce} ->
            PidB ! {get_headLocal, Mittente,Nonce},
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces);
        {'EXIT',_,_} -> 
            loop(FriendsList, NameNode, PidT, PidB, PidC, Nonces)
    end.


% aggiungo nodi fino a quando non raggiungo 3
addNodes(LengthFList,ListTemp) ->
    case LengthFList + length(ListTemp) > 3 of
        true ->                        
            addNodes(LengthFList, (ListTemp -- [lists:nth(rand:uniform(length(ListTemp)),ListTemp)]));
        false -> 
            ListTemp
    end.




start(NameNode) -> 
    Self = self(),
    process_flag(trap_exit, true), % deve essere posto prima di fare le spawn
    PidC = spawn_link(fun() -> start_C_act(Self) end), % attore delegato al check degli amici 
    PidB = spawn_link(fun() -> start_B_act(Self) end), % attore delegato alla gestione dei blocchi
    PidT = spawn_link(fun() -> start_T_act(Self,PidB) end), % attore delegato al gestione delle transazioni
    loop([],NameNode, PidT, PidB, PidC, []).

watchFriends(NewItems,Main) -> [spawn(fun()-> watch(Main,X) end) || X<-NewItems].

test() ->  
    io:format("Versione 1.5~n"),
    TIME = 2,
    TIME_TO_TRANS = 3,
    spawn(teacher_node,main,[]), % teacher_node
    sleep(1),
    
    N1 = spawn(?MODULE,start,["N1"]),
    io:format("~p -> ~p~n",["N1",N1]),
    sleep(TIME),
    
    N2 = spawn(?MODULE,start,["N2"]),
    io:format("~p -> ~p~n",["N2",N2]),
    sleep(TIME),

    N3 = spawn(?MODULE,start,["N3"]),
    io:format("~p -> ~p~n",["N3",N3]),
    sleep(TIME),
    
    N4 = spawn(?MODULE,start,["N4"]),
    io:format("~p -> ~p~n",["N4",N4]),

    % %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    sleep(17),
    io:format("Testing Transaction...~n"),
    Payload1 = "Ho comprato il pane",
    N1 ! {push, {make_ref(), Payload1}},
    sleep(TIME_TO_TRANS),
    Payload2 = "Ho comprato il pesce",
    N1 ! {push, {make_ref(), Payload2}},
    
    sleep(TIME_TO_TRANS),
    Payload3 = "Ho comprato il latte",
    N2 ! {push, {make_ref(), Payload3}},

    sleep(TIME_TO_TRANS),
    Payload4 = "Ho comprato la carne",
    N3 ! {push, {make_ref(), Payload4}},
    
    sleep(TIME_TO_TRANS),
    Payload5 = "Ho comprato il pesto",
    N2 ! {push, {make_ref(), Payload5}},
    
    sleep(TIME_TO_TRANS),
    Payload6 = "Ho comprato il succo",
    N1 ! {push, {make_ref(), Payload6}},

    io:format("End Transaction Send ~n"),
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    sleep(20),
    io:format("New Actors ~n"),
    N5 = spawn(?MODULE,start,["N5"]),
    io:format("~p -> ~p~n",["N5",N5]),
        
    sleep(TIME_TO_TRANS),
    Payload7 = "Ho comprato il vino",
    N1 ! {push, {make_ref(), Payload7}},


    spawn(fun()->
        PRINT = fun PRINT() ->
            sleep(20),
            io:format("----- ACTORS LIST ------~n"),
            io:format("~p -> ~p~n",["N1",N1]),
            io:format("~p -> ~p~n",["N2",N2]),
            io:format("~p -> ~p~n",["N3",N3]),
            io:format("~p -> ~p~n",["N4",N4]),
            io:format("~p -> ~p~n",["N5",N5]),
            io:format("-------------------------~n"),
            N2 ! {printC},
            N3 ! {printC},    
            N4 ! {printC},    
            N5 ! {printC},
            PRINT()
        end,
        PRINT()    
     end),
    

    sleep(20),
    exit(N1, kill),
    sleep(15),
    Payload8 = "Ho comprato la pizza",
    N2 ! {push, {make_ref(), Payload8}}.