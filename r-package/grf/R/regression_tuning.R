#' Regression forest tuning
#'
#' Finds the optimal parameters to be used in training a regression forest. This method
#' currently tunes over min.node.size, mtry, sample.fraction, alpha, and imbalance.penalty.
#' Please see the method 'regression_forest' for a description of the standard forest
#' parameters. Note that if fixed values can be supplied for any of the parameters mentioned
#' above, and in that case, that parameter will not be tuned. For example, if this method is
#' called with min.node.size = 10 and alpha = 0.7, then those parameter values will be treated
#' as fixed, and only sample.fraction and imbalance.penalty will be tuned.
#'
#' @param X The covariates used in the regression.
#' @param Y The outcome.
#' @param num.fit.trees The number of trees in each 'mini forest' used to fit the tuning model.
#' @param num.fit.reps The number of forests used to fit the tuning model.
#' @param num.optimize.reps The number of random parameter values considered when using the model
#'                          to select the optimal parameters.
#' @param sample.fraction Fraction of the data used to build each tree.
#'                        Note: If honesty = TRUE, these subsamples will
#'                        further be cut by a factor of honesty.fraction.
#' @param min.node.size A target for the minimum number of observations in each tree leaf. Note that nodes
#'                      with size smaller than min.node.size can occur, as in the original randomForest package.
#' @param mtry Number of variables tried for each split.
#' @param alpha A tuning parameter that controls the maximum imbalance of a split.
#' @param imbalance.penalty A tuning parameter that controls how harshly imbalanced splits are penalized.
#' @param honesty Whether or not honest splitting (i.e., sub-sample splitting) should be used.
#' @param honesty.fraction The fraction of data that will be used for determining splits if honesty = TRUE. Corresponds
#'                         to set J1 in the notation of the paper. When using the defaults (honesty = TRUE and
#'                         honesty.fraction = NULL), half of the data will be used for determining splits
#' @param clusters Vector of integers or factors specifying which cluster each observation corresponds to.
#' @param samples.per.cluster If sampling by cluster, the number of observations to be sampled from
#'                            each cluster. Must be less than the size of the smallest cluster. If set to NULL
#'                            software will set this value to the size of the smallest cluster.
#' @param compute.oob.predictions Whether OOB predictions on training set should be precomputed.
#' @param num.threads Number of threads used in training. By default, the number of threads is set
#'                    to the maximum hardware concurrency.
#' @param seed The seed of the C++ random number generator.
#'
#' @return A list consisting of the optimal parameter values ('params') along with their debiased
#'         error ('error').
#'
#' @examples \dontrun{
#' # Find the optimal tuning parameters.
#' n = 500; p = 10
#' X = matrix(rnorm(n*p), n, p)
#' Y = X[,1] * rnorm(n)
#' params = tune_regression_forest(X, Y)$params
#'
#' # Use these parameters to train a regression forest.
#' tuned.forest = regression_forest(X, Y, num.trees = 1000,
#'     min.node.size = as.numeric(params["min.node.size"]),
#'     sample.fraction = as.numeric(params["sample.fraction"]),
#'     mtry = as.numeric(params["mtry"]),
#'     alpha = as.numeric(params["alpha"]),
#'     imbalance.penalty = as.numeric(params["imbalance.penalty"]))
#' }
#'
#' @importFrom stats runif
#' @importFrom utils capture.output
#' @export
tune_regression_forest <- function(X, Y,
                                   sample.weights = NULL,
                                   num.fit.trees = 10,
                                   num.fit.reps = 100,
                                   num.optimize.reps = 1000,
                                   min.node.size = NULL,
                                   sample.fraction = 0.5,
                                   mtry = NULL,
                                   alpha = NULL,
                                   imbalance.penalty = NULL,
                                   honesty = TRUE,
                                   honesty.fraction = NULL,
                                   clusters = NULL,
                                   samples.per.cluster = NULL,
                                   num.threads = NULL,
                                   seed = NULL) {
  validate_X(X)
  validate_sample_weights(sample.weights, X)
  if(length(Y) != nrow(X)) { stop("Y has incorrect length.") }
  num.threads <- validate_num_threads(num.threads)
  seed <- validate_seed(seed)
  clusters <- validate_clusters(clusters, X)
  samples.per.cluster <- validate_samples_per_cluster(samples.per.cluster, clusters)
  ci.group.size <- 1
  honesty.fraction <- validate_honesty_fraction(honesty.fraction, honesty)

  data <- create_data_matrices(X, Y, sample.weights=sample.weights)
  outcome.index <- ncol(X) + 1
  sample.weight.index <- ncol(X) + 2
  # if no sample weights are stored, sample.weight.index is ncol(data) + 1 and is ignored

  # Separate out the tuning parameters with supplied values, and those that were
  # left as 'NULL'. We will only tune those parameters that the user didn't supply.
  all.params = get_initial_params(min.node.size, sample.fraction, mtry, alpha, imbalance.penalty)

  fixed.params = all.params[!is.na(all.params)]
  tuning.params = all.params[is.na(all.params)]

  if (length(tuning.params) == 0) {
    return(list("error"=NA, "params"=c(all.params)))
  }

  # Train several mini-forests, and gather their debiased OOB error estimates.
  num.params = length(tuning.params)
  fit.draws = matrix(runif(num.fit.reps * num.params), num.fit.reps, num.params)
  colnames(fit.draws) = names(tuning.params)
  compute.oob.predictions = TRUE

  debiased.errors = apply(fit.draws, 1, function(draw) {
    params = c(fixed.params, get_params_from_draw(X, draw))
    small.forest <- regression_train(data$default, data$sparse, outcome.index, sample.weight.index,
                                     !is.null(sample.weights),
                                     as.numeric(params["mtry"]),
                                     num.fit.trees,
                                     as.numeric(params["min.node.size"]),
                                     as.numeric(params["sample.fraction"]),
                                     honesty,
                                     coerce_honesty_fraction(honesty.fraction),
                                     ci.group.size,
                                     as.numeric(params["alpha"]),
                                     as.numeric(params["imbalance.penalty"]),
                                     clusters,
                                     samples.per.cluster,
                                     compute.oob.predictions,
                                     num.threads,
                                     seed)

    prediction = regression_predict_oob(small.forest, data$default, data$sparse,
        outcome.index, num.threads, FALSE)
    error = prediction$debiased.error
    mean(error, na.rm = TRUE)
  })

  # Fit the 'dice kriging' model to these error estimates.
  # Note that in the 'km' call, the kriging package prints a large amount of information
  # about the fitting process. Here, capture its console output and discard it.
  variance.guess = rep(var(debiased.errors)/2, nrow(fit.draws))
  env = new.env()
  capture.output(env$kriging.model <-
                   DiceKriging::km(design = data.frame(fit.draws),
                                   response = debiased.errors,
                                   noise.var = variance.guess))
  kriging.model <- env$kriging.model

  # To determine the optimal parameter values, predict using the kriging model at a large
  # number of random values, then select those that produced the lowest error.
  optimize.draws = matrix(runif(num.optimize.reps * num.params), num.optimize.reps, num.params)
  colnames(optimize.draws) = names(tuning.params)
  model.surface = predict(kriging.model, newdata=data.frame(optimize.draws), type = "SK")

  tuned.params = get_params_from_draw(X, optimize.draws)
  grid = cbind(error=model.surface$mean, tuned.params)
  optimal.draw = which.min(grid[, "error"])
  optimal.param = grid[optimal.draw, ]

  out = list(error = optimal.param[1], params = c(fixed.params, optimal.param[-1]),
             grid = grid)
  class(out) = c("tuning_output")

  out
}
