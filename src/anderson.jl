# To do: pass the storages f, ∆X, ∆F, Q, β.  Also, think about ways to reduce this memory.

# Solve the fixed-point equation g(x) = x to given relative and absolute tolerances,
# returning the solution x, via Anderson acceleration of a fixed-point iteration starting at
# a given initial x (which must be of the correct type to hold the result).
#
# This implementation operates in-place as much as possible.
function anderson_salt!(lsol::LasingSol,
                        lvar::LasingVar,
                        gp::GainProfile;
                        m::Integer=2, # number of additional x's kept in algorithm; m = 0 means unaccelerated iteration
                        τr::Real=1e-4,  # relative tolerance; consider using Base.rtoldefault(Float)
                        τa::Real=1e-8,  # absolute tolerance
                        maxit::Int=typemax(Int),  # number of maximum number of iteration steps
                        verbose::Bool=true,
                        msgprefix::String="    ")
    m ≥ 0 || throw(ArgumentError("m = $m must be ≥ 0."))
    τr ≥ 0 || throw(ArgumentError("τr = $τr must be ≥ 0."))
    τa ≥ 0 || throw(ArgumentError("τa = $τa must be ≥ 0."))
    maxit ≥ 0 || throw(ArgumentError("maxit = $maxit must be ≥ 0."))

    k = 0
    init_lvar!(lvar, lsol, gp)
    lleq₀ = norm_leq(lsol, lvar, gp)
    # verbose && println(msgprefix * "Anderson acceleration:")
    verbose && println(msgprefix * "Initial residual norm: ‖leq₀‖ = $lleq₀")
    lleq₀ ≤ τa && return k, lleq₀, lleq₀  # lsol.m_active = [] falls to this as well

    τ = max(τr*lleq₀, τa)

    x = lsol2rvec(lsol)
    n = length(x)
    m ≤ n || throw(ArgumentError("m = $m must be > length(lsol2rvec(lsol)) = $n."))

    # Storing xold is needed only for the m ≠ 0 case, so executing the following block only
    # for m ≠ 0 would have saved 1 allocation.  However, putting the following block here
    # increase code readability, because doing update_lsol! right after norm_leq is an idiom.
    # m ≠ 0 is rarely used anyway.
    T = eltype(x)
    xold = Vector{T}(undef, n)
    xold .= x  # xold = x₀
    update_lsol!(lsol, lvar, gp)  # x is updated to x₁ = g(x₀)
    # Note we need at least two x's to perform the m ≠ 0 Anderson acceleration.

    if m == 0 # simple fixed-point iteration (no memory)
        while (k+=1) ≤ maxit
            init_lvar!(lvar, lsol, gp)
            lleq = norm_leq(lsol, lvar, gp)
            verbose && println(msgprefix * "k = $k: ‖leq‖/‖leq₀‖ = $(lleq/lleq₀)")
            lleq ≤ τ && break
            update_lsol!(lsol, lvar, gp)
        end
    else  # m ≠ 0
        # Pre-allocate all of the arrays we will need.  The goal is to allocate once and re-use
        # the storage during the iteration by operating in-place.
        f = Vector{T}(undef, n)
        ∆X = Matrix{T}(undef, n, m)  # columns: ∆x's
        ∆F = Matrix{T}(undef, n, m)  # columns: ∆f's
        Q = Matrix{T}(undef, n, m)  # space for QR factorization
        β = Vector{T}(undef, max(n,m))  # not m, in order to store RHS vector (f: length-n) and overwrite in-place via ldiv! (max length m)

        # Find x₁ = g(x₀): we need at least two x's to perform the Anderson acceleration.
        col = 1
        for i = 1:n
            f[i] = x[i] - xold[i]  # f(x₀) = g(x₀) - x₀
            ∆X[i,col] = f[i]  # ∆x₀ = x₁ - x₀
        end
        # Note that in the subsequent iteration, xₖ₊₁ is not necessarily g(xₖ), so
        # ∆xₖ = xₖ₊₁ - xₖ is not necessarily f(xₖ) = g(xₖ) - xₖ.

        # Perform subsequent iterations.
        #
        # (Assumption) The following quantities are known at the beginning of every iteration:
        # - xₖ
        # - f(xₖ₋₁)
        # - ∆xₖ₋₁
        # These quantities must be updated at the end of the for loop to satisfy the
        # assumption at every iteration.
        #
        # Using these quantities, in each iteration
        # - g(xₖ) is calculated,
        # - with which f(xₖ) = g(xₖ) - xₖ is calculated,
        # - with which ∆fₖ₋₁ = f(xₖ) - f(xₖ₋₁) is calculated.
        #
        # Then we know ∆xₖ₋₁ and ∆fₖ₋₁, which are needed for the Anderson acceleration.
        while (k+=1) ≤ maxit
            init_lvar!(lvar, lsol, gp)
            lleq = norm_leq(lsol, lvar, gp)
            verbose && println(msgprefix * "k = $k: ‖leq‖/‖leq₀‖ = $(lleq/lleq₀)")
            lleq ≤ τ && break

            # Evaluate g(xₖ).
            xold .= x  # xold = xₖ
            update_lsol!(lsol, lvar, gp)  # x is updated to g(xₖ) (but this x is not xₖ₊₁)

            # Prepare the least squares problem.
            for i = 1:n
                β[i] = x[i] - xold[i]  # temporary storage for f(xₖ) = g(xₖ) - xₖ
                ∆F[i,col] = β[i] - f[i]  # ∆fₖ₋₁ = f(xₖ) - f(xₖ₋₁)
                f[i] = β[i]  # f(xₖ)
            end

            # Solve the least squares problem.
            #
            # The code overwrites β with ∆F′ \ f.  (Note that β stores f at this point.)
            # Only first m′ entries of the solution β are meaningful, because they are the
            # entries of the least squares solution.
            #
            # In the following, QR′ and QR have different types, so we introduce separate
            # variables for type stability.
            if k < m
                # Construct subarrays to work in-place on a subset of the columns.
                Q′, ∆F′ = @views Q[:,1:k], ∆F[:,1:k]
                QR′ = qr!(copyto!(Q′, ∆F′), Val(true))
                ldiv!(QR′, β)
            else
                QR = qr!(copyto!(Q, ∆F), Val(true))
                ldiv!(QR, β)
            end

            # Replace the columns of ∆X (and ∆F in the next iteration) with the new data
            # in-place.  Rather than always appending the new data in the last column, cycle
            # through the m columns periodically.
            col = mod1(col+1, m)  # next column of ∆X and ∆F to update
            for i = 1:n
                # Update x with xₖ₊₁ = xₖ + fₖ - (∆X′ + ∆F′)*β′.
                # Note that x is already g(xₖ) = xₖ + f(xₖ)
                for j = 1:min(m,k)
                    x[i] -= (∆X[i,j] + ∆F[i,j]) * β[j]
                end

                ∆X[i,col] = x[i] - xold[i]  # ∆xₖ = xₖ₊₁ - xₖ
            end
        end  # for k = 1:maxit-1
    end  # if m == 0

    if k == maxit  # iteration terminated by consuming maxit steps
        init_lvar!(lvar, lsol, gp)
        lleq = norm_leq(lsol, lvar, gp)
        verbose && println(msgprefix * "k = $k: ‖leq‖/‖leq₀‖ = $(lleq/lleq₀)")
        @warn "Anderson reached maxit = $maxit and didn't converge."
    end

    return k, lleq, lleq₀
end
