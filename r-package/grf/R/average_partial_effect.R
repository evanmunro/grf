#' Estimate average partial effects using a causal forest
#' 
#' Gets estimates of the average partial effect, in particular
#' the (conditional) average treatment effect (target.sample = all):
#'   1/n sum_{i = 1}^n Cov[Wi, Yi | X = Xi] / Var[Wi | X = Xi].
#' Note that for a binary unconfounded treatment, the
#' average partial effect matches the average treatment effect.
#' 
#' If clusters are specified, then each cluster gets equal weight. For example,
#' if there are 10 clusters with 1 unit each and per-cluster APE = 1, and there
#' are 10 clusters with 19 units each and per-cluster APE = 0, then the overall
#' APE is 0.5 (not 0.05).
#'
#' @param forest The trained forest.
#' @param calibrate.weights Whether to force debiasing weights to match expected
#'                          moments for 1, W, W.hat, and 1/Var[W|X].
#' @param subset Specifies a subset of the training examples over which we
#'               estimate the ATE. WARNING: For valid statistical performance,
#'               the subset should be defined only using features Xi, not using
#'               the treatment Wi or the outcome Yi.
#' @param num.trees.for.variance Number of trees used to estimate Var[Wi | Xi = x].
#'
#' @examples \dontrun{
#' n = 2000; p = 10
#' X = matrix(rnorm(n*p), n, p)
#' W = rbinom(n, 1, 1/(1 + exp(-X[,2]))) + rnorm(n)
#' Y = pmax(X[,1], 0) * W + X[,2] + pmin(X[,3], 0) + rnorm(n)
#' tau.forest = causal_forest(X, Y, W)
#' tau.hat = predict(tau.forest)
#' average_partial_effect(tau.forest)
#' average_partial_effect(tau.forest, subset = X[,1] > 0)
#' }
#'
#' @return An estimate of the average partial effect, along with standard error.
#' @export
average_partial_effect = function(forest,
                                  calibrate.weights = TRUE,
                                  subset = NULL,
                                  num.trees.for.variance = 500) {
  
  if (!("causal_forest" %in% class(forest))) {
    stop("Average effect estimation only implemented for causal_forest")
  }

  if (is.null(subset)) {
    subset <- 1:length(forest$Y.hat)
  }
  
  if (class(subset) == "logical" & length(subset) == length(forest$Y.hat)) {
    subset <- which(subset)
  }
  
  if (!all(subset %in% 1:length(forest$Y.hat))) {
    stop(paste("If specified, subset must be a vector contained in 1:n,",
               "or a boolean vector of length n."))
  }

  cluster.se <- length(forest$clusters) > 0
  clusters = if(cluster.se) { forest$clusters } else { 1:length(forest$Y.hat) }
  observation.weight = observation_weights(forest)

  # Only use data selected via subsetting.
  subset.X.orig <- forest$X.orig[subset, , drop = FALSE]
  subset.W.orig <- forest$W.orig[subset]
  subset.W.hat <- forest$W.hat[subset]
  subset.Y.orig <- forest$Y.orig[subset]
  subset.Y.hat <- forest$Y.hat[subset]
  tau.hat <- predict(forest)$predictions[subset]
  subset.clusters <- clusters[subset]
  subset.weights <- observation.weight[subset]
  
  # This is a simple plugin estimate of the APE.
  cape.plugin <- weighted.mean(tau.hat, subset.weights)
  
  # Estimate the variance of W given X. For binary treatments,
  # we get a good implicit estimator V.hat = e.hat (1 - e.hat), and
  # so this step is not needed. Note that if we use the present CAPE estimator
  # with a binary treatment and set V.hat = e.hat (1 - e.hat), then we recover
  # exactly the AIPW estimator of the CATE.
  variance_forest <- regression_forest(subset.X.orig,
                                       (subset.W.orig - subset.W.hat)^2,
                                       clusters = subset.clusters,
                                       num.trees = num.trees.for.variance)
  V.hat <- predict(variance_forest)$predictions
  debiasing.weights <- subset.weights * (subset.W.orig - subset.W.hat) / V.hat
  
  # In the population, we want A' %*% weights = b.
  # Modify debiasing weights gamma to make this true, i.e., compute
  # argmin {||gamma - gamma.original||_2^2 : A'gamma = b}
  if (calibrate.weights) {
    A = cbind(1, subset.W.orig, subset.W.hat) / sum(subset.weights)
    b = c(0, 1, 0)
    bias = t(A) %*% debiasing.weights - b
    lambda = solve(t(A) %*% A, bias)
    correction = A %*% lambda
    debiasing.weights = debiasing.weights - correction
  }
  
  # Compute a residual-based correction to the plugin.
  plugin.prediction = subset.Y.hat + (subset.W.orig - subset.W.hat) * tau.hat
  plugin.residual = subset.Y.orig - plugin.prediction
  cape.correction = mean(debiasing.weights * plugin.residual)
  cape.estimate = cape.plugin + cape.correction
  
  # Estimate variance using the calibration
  if (length(subset.clusters) == 0) {
    cape.se = sqrt(mean((debiasing.weights * plugin.residual)^2) / (length(subset.W.orig) - 1))
  } else {
    debiasing.clust = Matrix::sparse.model.matrix(
      ~ factor(subset.clusters) + 0,
      transpose = TRUE) %*% (debiasing.weights * plugin.residual)
    cape.se = sqrt(sum(debiasing.clust^2) / length(debiasing.clust) /
                     (length(debiasing.clust) - 1))
  }
  
  return(c(estimate=cape.estimate, std.err=cape.se))
}

