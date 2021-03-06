library(grf)

set.seed(1)

test_that("Boosted regression forest improves performance vs regular forest", {

  n <- 500; p <- 6
  X <- matrix(runif(n * p), n, p)
  mu <- 2 * X[,1] * X[,2] + 3 * X[,3] + 4 * X[,4]
  Y <- mu + rnorm(n)
  forest.regular <- regression_forest(X,Y)
  forest.boost <- boosted_regression_forest(X,Y)

  forest.Yhat <- predict(forest.regular)$predictions
  boost.Yhat <- predict(forest.boost)$predictions

  mse.forest <- mean((Y-forest.Yhat)^2)
  mse.boost <- mean((Y- boost.Yhat)^2)
  expect_true(mse.boost < mse.forest)
})


test_that("Boosted forest takes user specified number of steps",  {
  n <- 100; p <- 6
  X <- matrix(runif(n * p), n, p)
  mu <- 2 * X[,1] * X[,2] + 3 * X[,3] + 4 * X[,4]
  Y <- mu + rnorm(n)
  forest.boost <- boosted_regression_forest(X,Y,boost.steps=2)
  expect_equal(2,length(forest.boost$forests))
})

test_that("Under cross-validation, errors decrease each step", {
  n<-200; p<-6
  X <- matrix(runif(n * p), n, p)
  mu <- 2 * X[,1]^2 * X[,2] + 3 * X[,3] + 4 * X[,4]
  Y <- mu + rnorm(n)
  forest.boost <- boosted_regression_forest(X,Y)
  errors <- unlist(forest.boost$error)
  if(length(errors)>1) {
    improves <- errors[2:length(errors)] - errors[1:(length(errors)-1)]
    expect_true(all(improves<0))
  }
})

test_that("boost.error.reduction validation works", {
  n<-200; p<-6
  X <- matrix(runif(n * p), n, p)
  mu <- 2 * X[,1]^2 * X[,2] + 3 * X[,3] + 4 * X[,4]
  Y <- mu + rnorm(n)
  expect_error(forest.boost <- boosted_regression_forest(X,Y,boost.error.reduction=1.5))
})

test_that("OOB prediction is close to actual out of sample error", {
  n<-3000; p<-6
  X <- matrix(runif(n * p), n, p)
  mu <- 2 * X[,1]^2 * X[,2] + 3 * X[,3] + 4 * X[,4]
  Y <- mu + rnorm(n)
  test <- 2000:3000
  train <- 1:2000
  forest.boost <- boosted_regression_forest(X[train,],Y[train])
  OOB.error <- mean((forest.boost$predictions - Y[train])^2)

  test.pred <- predict(forest.boost,newdata=X[test,])$predictions
  test.error <- mean((Y[test]- test.pred)^2)

  expect_true(abs((test.error - OOB.error)/test.error) < 0.05)
})
