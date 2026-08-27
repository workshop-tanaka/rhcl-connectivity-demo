/**
 * Jest direto, sem o `backstage-cli package test`.
 *
 * Fora de um monorepo o wrapper do CLI nao resolve a role do pacote: ele assume
 * ambiente de navegador e exige jest-environment-jsdom para testar funcao pura
 * de backend, e trava antes de rodar um unico caso. O transform do swc que ele
 * usaria esta aqui do mesmo jeito -- so o intermediario saiu.
 */
module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/src'],
  transform: { '^.+\\.tsx?$': '@swc/jest' },
  testMatch: ['**/*.test.ts'],
};
