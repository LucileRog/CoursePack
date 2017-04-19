

module nfxp


    # theta is the parameter vector.
    # it contains
    # theta[1] = RC
    # theta[2] = variable cost parameter
    # theta[3:end] = transition probabilities on mileage grid

    using Logging
    using Plots, NLopt , Optim
    using ShowItLikeYouBuildIt
    pyplot()
    Logging.configure(level=DEBUG)

        # function P = statetransition(p, n)
        #     p=[p; (1-sum(p))];
        #     P=0;
        #     for i=0:numel(p)-1;
        #         P=P+sparse(1:n-i,1+i:n,ones(1,n-i)*p(i+1), n,n);
        #         P(n-i,n)=1-sum(p(1:i));
        #     end
        #     P=sparse(P);
        
    type Param
        # opts
        max_fxpiter :: Int
        min_cstp    :: Int
        max_cstp    :: Int
        ctol        :: Float64
        rtol        :: Float64
        nstep       :: Int
        ltol0       :: Float64
        tol_vfi     :: Float64
        rtolnk      :: Float64
        hessian     :: Symbol
        converged   :: Bool
        n_params  :: Int  # number of params to estimate
        theta :: Vector{Float64}

        # spaces
        n :: Int  # num of grid points
        max :: Int # upper boudn of mileage grid

        # structural params
        pr :: Vector{Float64}  # transition probs
        RC :: Float64         # replacement cost
        c :: Float64  # cost parameter
        beta :: Float64 # discount factor

        # computation objects
        grid :: LinSpace{Float64}
        P :: SparseMatrixCSC{Float64,Int64}
        EV0 :: Vector{Float64}   # old value function   
        EV1 :: Vector{Float64}   # new
        pk :: Vector{Float64}  # probability of keeping engine
        cost :: Vector{Float64}   #operating cost

        """
            create default param type
        """
        function Param(;max_fxpiter = 5,
                        min_cstp = 4,
                        max_cstp = 2000000,
                        ctol = 0.01,
                        rtol = 0.02,
                        nstep = 20,
                        ltol0 = 1.0e-10,
                        tol_vfi = 1.0e-6,
                        rtolnk = 0.5,
                        hessian = :bhhh)
            this = new()
            this.max_fxpiter=max_fxpiter
            this.min_cstp=min_cstp
            this.max_cstp =max_cstp 
            this.ctol  =ctol  
            this.rtol  =rtol  
            this.nstep =nstep 
            this.ltol0 =ltol0 
            this.tol_vfi =tol_vfi 
            this.rtolnk=rtolnk
            this.hessian =hessian 
            this.converged = false

            this.n = 175
            this.max = 450
            this.grid = 0.0:(this.n-1)

            this.pr = [0.0937; 0.4475; 0.4459; 0.0127]
            this.RC = 11.7257
            this.c = 2.45569
            this.theta = vcat(this.RC,this.c,this.pr)
            this.n_params = length(this.theta)
            this.beta = 0.9999
            this.P = build_trans(this.pr,this.n)
            this.cost = 0.001*this.c*collect(this.grid)
            this.EV0 = zeros(this.n)
            this.EV1 = zeros(this.n)
            this.pk = zeros(this.n)
            return this
        end
    end
    function update!(p::Param,theta::Vector{Float64})
        p.RC = theta[1]
        p.c = theta[2]
        if length(theta) > 2
            p.pr = theta[3:end]
            p.P = build_trans(p.pr,p.n)
        end
        p.n_params = length(theta)
        p.cost = 0.001*p.c*collect(p.grid)
        p.EV0[:] = 0.0
        p.EV1[:] = 0.0
        p.pk[:] = 0.0
        p.converged = false
        p.theta = vcat(p.RC,p.c,p.pr)
    end

    """
        build_trans(p::Vector{Float64},n::Int)

    Build transition matrix for each of `n` states where each element `p[j]` of `p` is the probability of moving `j-1` states up in the grid defined by `1:n`.
    """ 
    function build_trans(p::Vector{Float64},n::Int)
        P = spzeros(n,n)
        p = vcat(p,(1-sum(p)))
        N = length(p)
        for i=0:(N-1)
            P =   P + sparse(1:(n-i),(1+i):n,ones(n-i)*p[i+1],n,n)
            P[n-i,n] = 1-sum(p[1:i])
        end
        return P
    end





    function bellman!(p::Param,probs=false)
        vk = -p.cost .+ p.beta .* p.EV0  # value of keep at each state
        vr = -p.RC - p.cost[1] + p.beta*p.EV0[1]
        maxv = maximum(vk)
        #recenter expected value function by substracting max value
        p.EV1[:] = p.P * (maxv +  log(exp(vk-maxv) + exp(vr-maxv)))

        # compute choice probs
        if probs
            p.pk[:] = 1.0 ./ (1.0+ (exp(vr-vk)))
        end
    end

    # get Frechet derivative of Bellman operator
    function dbellman(p::Param)
        tmp = p.P[:,2:p.n] .* repmat(p.pk[2:p.n,1]',p.n,1)
        p.beta * hcat((1.0 .- sum(tmp,2)), tmp)
    end
    function dbellman2(p::Param)
        dGamma_dEV = p.beta * (p.P .* repmat(p.pk,1,p.n))
        # println(size(dGamma_dEV))
        dGamma_dEV[:,1] = dGamma_dEV[:,1] .+ p.beta*p.P*(1.0-p.pk)
        # println(size(dGamma_dEV))
        return dGamma_dEV
    end

    update_ev!(p::Param) = copy!(p.EV0,p.EV1);

    """
        VFI(p::Param)

    Standard value function iteration
    """
    function VFI!(p::Param)
        iter = 0
        for j in 1:p.max_cstp  # do max_cstp contraction steps
            iter += 1
            bellman!(p)
            dist_vfi = maxabs(p.EV0.-p.EV1)
            update_ev!(p)
            # p.EV0[:] = p.EV1[:]
            if dist_vfi < p.tol_vfi
                p.converged = true
                info("after $iter iterations")
                break
            end
        end
        if maxabs(p.EV0.-p.EV1) > p.tol_vfi
            info("not converged")
        end
        bellman!(p,true)    # get choice probs
        # plot(1.0-p.pk,ylimits=[0;1])
    end

    function likelihood!(new_theta::Vector{Float64},grad::Vector{Float64},data::Dict,p::Param)

        # if we want the likelihood at a new parameter theta:
        update!(p,new_theta)
        println("current theta = $(p.theta)")

        n_c = length(p.c)
        N = length(data[:x])

        # solve model
        VFI!(p)
        fval = 1e10

        # try

            # evaluate log likelihood of replacement decision
            # at each state
            ccps = p.pk[data[:x]]  # get ccp of keep at each state in the data
            log_like = log( ccps .+ (1.0-2.0*ccps) .* (data[:d]))

            # add log likelihood for exogenous mileage increases
            n_p = 0
            pr = Float64[]
            if length(new_theta) > 2
                pr = [p.pr ; 1.0 - sum(p.pr)]
                n_p = length(pr)-1
                # if any(pr[1+data[:dx1]] .< 0)
                #     # println(sum(pr[1+data[:dx1]] .< 0))
                # end
                idx1 = clamp(data[:dx1],1,maximum(data[:dx1]))
                log_like[:] = log_like[:] .+ log(pr[idx1])
            end
            # println("n_p=$n_p")

            # ojbective function value
            fval = mean(-log_like)

            # save all of this

            # compute gradient of likelihood function

            N = size(data[:x],1)

            if length(grad)>0
                #1. derivative of bellman equation wrt parameters
                dc=0.001*p.grid;    # deriv of cost function
                dtdmp = zeros(p.n,1+n_c+n_p)  # gradient matrix of bellman operator
                dtdmp[:,1] = p.P * p.pk - 1   # wrt RC
                dtdmp[:,2:(1+n_c)] = -(p.P * dc) .*p.pk  # wrt c
                if length(new_theta) > 2   # wrt pr
                    vk = -p.cost + p.beta*p.EV1
                    vr = -p.RC - p.cost[1] + p.beta*p.EV1[1]
                    vmax = max(vk,vr)
                    dtp = vmax + log(exp(vk-vmax)+exp(vr-vmax))

                    for iP in 1:n_p
                        dtdmp[1:(p.n-iP),1+n_c+iP] = dtp[iP:(end-1)] .- vcat(dtp[(n_p+1):p.n],Float64[dtp[end] for i in 1:(n_p-iP)])
                    end
                    invp = exp(-log(pr))
                    invp = vcat(sparse(1:n_p,1:n_p,invp[1:n_p],n_p,n_p),
                               -ones(1,n_p)*invp[n_p+1])
                end
                #2. Derivative of ev wrt parameters:
                F=speye(p.n) - dbellman2(p) 
                devdmp = F\dtdmp
                # print("devdmp=$(size(devdmp))")
                # print("devdmp=$(size(devdmp[data[:x],:]))")

                # step 3 get derivative of loglike wrt parameters
                score = (ccps-1 .+ data[:d] ) .* (hcat(-ones(N), dc[data[:x]], zeros(N,n_p) ) .+ (devdmp[ones(Int,N),:] .- devdmp[data[:x],:])) 
                if length(new_theta) > 2   # wrt pr
                    idx1 = clamp(data[:dx1],1,maximum(data[:dx1]))
                    for iP in 1:n_p
                        score[:,1+n_c+iP] = score[:,1+n_c+iP] + invp[idx1,iP]
                    end
                end
                grad[:] = mean(-score,1)
            end

        # catch
        #     fval = 1e9
        # end

        # we don't do the hessian.
        # enough is enough. :-)

        println("fval=$fval")

        return fval



    end

    function simdata(N::Int,T::Int,p::Param)
        if !p.converged
            info("solving model")
            VFI!(p)
        end
        id = reshape(repeat(1:N,inner=1,outer=T),N,T)
        t  = reshape(repeat(1:T,inner=N,outer=1),N,T)
        shock_dx = rand(N,T)
        shock_d = rand(N,T)

        x = zeros(Int,N,T)
        x1 = zeros(Int,N,T)
        x[:,1] = ones(Int,N)
        d = zeros(Bool,N,T)

        # uncontrolled transition on odometer x
        csum_p = cumsum(p.pr)
        dx1 = zeros(Int,N,T)
        for i in 1:length(csum_p)
            dx1 += (shock_dx.<csum_p[i])   # increases are random
        end

        for it in 1:T 
            for i in 1:N
                if x[i,it] == 0
                    println(x[i,:])
                    println(d[i,:])
                end
                d[i,it] = shock_dx[i,it] < (1.0-p.pk[x[i,it]]) ? true : false
                # make odometer progress
                x1[i,it] = min( d[i,it] * dx1[i,it] + (1-d[i,it])*(x[i,it] + dx1[i,it]) , p.n)
                if it < T
                    x[i,it+1] = x1[i,it]
                end
            end

        end
        return Dict(:id => id[:],:t => t[:], :d => convert(Array{Int},d[:]), :x => x[:],:x1 => x1[:], :dx1 => dx1[:])
    end

    function MC(p::Param;N=50,T=150)
        d = simdata(N,T,p)

        # estimate pr transition probs
        probs = freqtable(d[:dx1][d[:dx1].>0]) ./ sum(freqtable(d[:dx1][d[:dx1].>0]))

        # put those values into the param type
        update!(p,[p.RC;p.c;probs.array])

        # maximize likelihood
    end

    function myconstraint(x::Vector,gr::Vector)
        if length(gr)>0
            gr[1] = 0
            gr[2] = 0
            gr[3:end] = 1.0
        end
        sum(x[3:end]) - 1.0 # < 0
    end

    function check_like()
        p = Param()
        d = simdata(10000,50,p)
        pg = [Float64[x,p.theta[2:end]...] for x in linspace(1.0,20,20)]
        y = zeros(20)
        for i in eachindex(pg)
            y[i] = likelihood!(pg[i],zeros(6),d,p)
        end
        return y

    end

    function max_nlopt()
        p = Param()
        d = simdata(10000,50,p)
        f_closure(x,g) = likelihood!(x,g,d,p)
        opt = Opt(:LD_MMA,p.n_params)
        # opt = Opt(:LN_COBYLA,p.n_params)
        lower_bounds!(opt,[-Inf,-Inf,[0.0 for i in 1:4]...])
        upper_bounds!(opt,[Inf,Inf,[1.0 for i in 1:4]...])
        min_objective!(opt,f_closure)

        inequality_constraint!(opt,myconstraint)

        (minf,minx,ret) = NLopt.optimize(opt, [10.0,0.0001,0.1,0.1,0.1,0.1] )
        # (minf,minx,ret) = NLopt.optimize(opt, p.theta )
    end
    function max_optim()
        p = Param()
        d = simdata(10000,50,p)
        f_closure(x) = likelihood!(x,Float64[],d,p)
        lower = [-Inf,-Inf,[0.0 for i in 1:4]...]
        upper = [Inf,Inf,[1.0 for i in 1:4]...]
        res = Optim.optimize(OnceDifferentiable(f_closure),p.theta,lower,upper,Fminbox())
        return res
    end

end  # module